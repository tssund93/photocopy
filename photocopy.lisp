(defpackage :photocopy
  (:use :cl
        :parser.ini
        :trivial-types
        :cl-utilities
        :cl-fad)
  (:use :photocopy.app-utils)
  (:export :-main))

(in-package :photocopy)

(defparameter *version-number* "1.1.4"
  "Version number of application.")

(defvar *device-ids* (make-hash-table :test 'equal)
  "Hash table of badge numbers by device ID.")
(defvar *settings* (make-hash-table :test 'equal)
  "Hash table to hold general settings from ini file.")

(defparameter *progress-bar-length* 50
  "Length of progress bars for file transfer.")

(defparameter *waiting-message* "Waiting for USB device...~%~%"
  "Message to show when waiting for a USB to be inserted.")

(defparameter *default-expiration-days* 14
  "Default value for expiration days when not provided in INI or if invalid (in days).")
(defparameter *default-clean-frequency* 3600
  "Default value for clean frequency when not provided in INI or if invalid (in seconds).")
(defparameter *default-check-frequency* 5
  "Default value for check frequency when not provided in INI or if invalid (in seconds).")

(defparameter *max-retry-count* 1
  "Number of times to retry file copy, should it fail.")

(defvar *ignore-file-list* ()
  "Files to ignore on USB.  Don't copy these files, or delete them.")

(defvar *lock* (bt:make-lock)
  "Lock for threads")

(defun -main (&optional args)
  (format t "photocopy v~a~%~%" *version-number*)
  (handler-case
      (let* ((ini-file (or (when (and (string/= (second args) "-d")
                                      (string/= (second args) "--debug"))
                             (second args))
                           "config.ini"))
             (ini (cond ((file-exists-p ini-file)
                         (parse (normalize-line-endings (read-ini-to-string ini-file))
                                'list))
                        (t (format t "Could not open config file \"~a\": File not found
Press enter to exit...~%"
                                   ini-file)
                           (read-line)
                           (return-from -main))))
             (debug (or (position "-d" args :test 'string=)
                        (position "--debug" args :test 'string=))))
        (ini-badges-to-hash-table (get-ini-section ini "DEVICE-BADGE") *device-ids*)
        (ini-section-to-hash-table (get-ini-section ini "GENERAL") *settings*)
        (setf *ignore-file-list*
              (split-sequence #\, (gethash "ignoreFileList" *settings*)))
        (let ((check-frequency (or (parse-integer
                                    (gethash "checkFrequency" *settings*)
                                    :junk-allowed t)
                                   *default-check-frequency*))
              (clean-frequency (or (parse-integer
                                    (gethash "cleanFrequency" *settings*)
                                    :junk-allowed t)
                                   *default-clean-frequency*))
              (expiration-days (or (parse-integer
                                    (gethash "expirationDays" *settings*)
                                    :junk-allowed t)
                                   *default-expiration-days*))
              (vault-path (uiop/pathname:ensure-directory-pathname
                           (gethash "vault" *settings*)))
              (viewable-path (uiop/pathname:ensure-directory-pathname
                              (gethash "viewable" *settings*))))
          (when debug
            (print-debug-config vault-path
                                viewable-path
                                check-frequency
                                clean-frequency
                                expiration-days
                                *ignore-file-list*
                                ini-file
                                *settings*
                                *device-ids*))
          (ensure-directories-exist viewable-path)
          (ensure-directories-exist vault-path)
          (cleaning-loop expiration-days clean-frequency)
          (bt:with-lock-held
              (*lock*)
            (format t *waiting-message*))
          (copy-loop check-frequency debug)))
    (error (c) (progn (format t "~a~%~%Press enter to exit...~%" c)
                      (read-line)
                      (return-from -main)))))

(defun print-debug-config (vault-path viewable-path check-frequency clean-frequency
                           expiration-days ignore-file-list ini-file settings device-ids)
  "Print debug information relating to the configuration file."
  (format t
          "Loaded configuration as:
vaultPath=~s
viewablePath=~s
checkFrequency=~d
cleanFrequency=~d
expirationDays=~d
ignoreFileList=~s

From values in ~s:
~s

Device Mapping:
~s~%~%"
          vault-path
          viewable-path
          check-frequency
          clean-frequency
          expiration-days
          ignore-file-list
          ini-file
          settings
          device-ids))

(defun cleaning-loop (expiration-days clean-frequency)
  "Spawn a new thread that deletes files older than `expiration-days' every `clean-frequency'
seconds."
  (bt:make-thread
   (lambda ()
     (loop
       (bt:with-lock-held
           (*lock*)
         (format t "Deleting files more than ~d days old from viewable directory...~%"
                 expiration-days)
         (clean-old-files expiration-days
                          (gethash "viewable" *settings*)))
       (sleep clean-frequency)))
   :name "clean-files"))

(defun copy-loop (check-frequency debug)
  "Checks for USB every `check-frequency' seconds and if found, copies all files from it to
vault and viewables folders.  If `debug' is T, print debug info."
  (loop
    (bt:with-lock-held
        (*lock*)
      (import-from-usb *device-ids*
                       (gethash "vault" *settings*)
                       (gethash "viewable" *settings*)
                       debug))
    (sleep check-frequency)))

(defmethod print-object ((object hash-table) stream)
  (format stream "#HASH{~{~{~s ~s~}~^,~%      ~}}"
          (loop for key being the hash-keys of object
                  using (hash-value value)
                collect (list key value))))

(defun read-ini-to-string (file-path)
  "Read INI file at `file-path' to a string."
  (declare ((or pathname string) file-path))
  (let ((string (make-array '(0) :element-type 'character
                                 :adjustable t
                                 :fill-pointer 0)))
    (with-open-file (f file-path)
      (loop for char = (read-char f nil :eof)
            until (eql char :eof) do (vector-push-extend char string)))
    (the string string)))

(defun normalize-line-endings (string)
  "Remove carriage returns to normalize line endings to unix-style."
  (declare (string string))
  (remove #\Return string))

(defun get-ini-section (ini section-name)
  "Get section from `ini' that was returned by `parser.ini:parse'
with `section-name'."
  (declare ((proper-list property-list) ini)
           (string section-name))
  (loop for section in ini
        when (equal (getf section :name) (list section-name))
          return (the (proper-list (proper-list property-list))
                      (getf (getf section :section)
                            :section-option))))

(defun ini-section-to-hash-table (section table)
  "Populate `table' hash table with keys and values from `section'."
  (declare ((proper-list (proper-list property-list)) section)
           (hash-table table))
  (loop for setting in section
        do (let* ((setting-plist (first setting))
                  (key (first (getf setting-plist :name)))
                  (value (getf setting-plist :value)))
             (setf (gethash key table) value)))
  table)

(defun ini-badges-to-hash-table (section table)
  "Populate `table' hash table with contents from `section', with keys being comma
separated values on the right and values being the badge numbers on the left."
  (declare ((proper-list (proper-list property-list)) section)
           (hash-table table))
  (loop for setting in section
        do (let* ((setting-plist (first setting))
                  (badge-number (first (getf setting-plist :name)))
                  (value (getf setting-plist :value))
                  (device-ids (split-sequence #\, value)))
             (loop for device-id in device-ids
                   do (setf (gethash device-id table) badge-number))))
  table)

(defun copy-files (from to skip-if-exists &optional location-description)
  "Copy all files from `from' to `to', if `skip-if-exists' is T, will skip files
already in `to'.  `location-description' is just used for output."
  (declare ((or pathname string (proper-list pathname)) from)
           ((or pathname string) to))
  (let* ((from (if (or (pathnamep from)
                       (stringp from))
                   (uiop/pathname:ensure-directory-pathname from)
                   from))
         (to (uiop/pathname:ensure-directory-pathname to))
         (total-file-count (if (or (pathnamep from)
                                   (stringp from))
                               (file-count from skip-if-exists to)
                               (length from)))
         (current-file-count 1)
         (failed ()))
    (ensure-directories-exist to)
    (flet ((copy (file)
             (let ((new-file (merge-pathnames-as-file
                              to
                              (file-namestring file))))
               (unless (or (and skip-if-exists
                                (file-exists-p new-file))
                           (position (file-namestring file)
                                     *ignore-file-list*
                                     :test 'string-equal))
                 (format t "[~d/~d] "
                         current-file-count
                         total-file-count)
                 (unless (copy-file-with-progress
                          file
                          new-file
                          location-description)
                   (setf failed (cons file failed)))
                 (incf current-file-count)))))
      (typecase from
        ((or pathname string) (walk-directory from #'copy))
        ((proper-list pathname) (map nil #'copy from)))
      (if failed
          (values nil failed)
          t))))

(defun copy-file-with-progress (from to &optional location-description)
  "Copy file from `from' to `to', hopefully with a nice progress bar.
`location-description' is just used for output."
  (declare (pathname from)
           (pathname to))
  (handler-case
      (let ((buf-size 4096))
        (with-open-file (input-stream from
                                      :direction :input
                                      :element-type '(unsigned-byte 8))
          (with-open-file (output-stream to
                                         :direction :output
                                         :if-exists :supersede
                                         :if-does-not-exist :create
                                         :element-type '(unsigned-byte 8))
            (let ((buf (make-array buf-size :element-type (stream-element-type input-stream)))
                  (total-bytes (file-length input-stream)))
              (format t "Copying file ~a~@[ to ~a~]...~%"
                      (file-namestring from)
                      location-description)
              (loop for pos = (read-sequence buf input-stream)
                    with progress = 0
                    with progress-bar-size = 0
                    while (plusp pos)
                    do (progn
                         (incf progress pos)
                         (when (> (floor (* *progress-bar-length*
                                            (/ progress total-bytes)))
                                  progress-bar-size)
                           (format t "=")
                           (finish-output)
                           (incf progress-bar-size))
                         (write-sequence buf output-stream :end pos))
                    finally (when (< progress-bar-size *progress-bar-length*)
                              (format t
                                      "~v@{~A~:*~}"
                                      (- *progress-bar-length* progress-bar-size)
                                      "=")))
              (format t "~%"))))
        (format t "Verifying copy...~%")
        (if (files-equivalent-p from to)
            (progn (format t " OK~%~%")
                   t)
            (progn (format t " FAILED~%~%")
                   (uiop/filesystem:delete-file-if-exists to)
                   nil)))
    (error (c) (progn (format t "Copying file from ~s to ~s failed: ~a~%" from to c)
                      (uiop/filesystem:delete-file-if-exists to)))))

(defun file-count (directory &optional skip-if-exists dest-directory)
  "Get number of files in a `directory' (recursively).  If `skip-if-exists' is T,
don't count files that are in `dest-directory'."
  (declare ((or string pathname) directory)
           ((or null pathname) dest-directory))
  (when (and skip-if-exists (not dest-directory))
    (error "dest-directory must be provided if skip-if-exists is provided."))
  (let ((counter 0))
    (walk-directory (format nil "~a/" directory)
                    (lambda (file)
                      (declare (ignorable file))
                      (unless (or (and skip-if-exists
                                       (probe-file (merge-pathnames-as-file
                                                    (uiop/pathname:ensure-directory-pathname dest-directory)
                                                    (file-namestring file))))
                                  (position (file-namestring file)
                                            *ignore-file-list*
                                            :test 'string-equal))
                        (incf counter))))
    counter))

(defvar *whitespace-chars* '(#\Space #\Newline #\Backspace #\Tab
                             #\Linefeed #\Page #\Return #\Rubout))

(defun whitespacep (character)
  "Check if `character' is whitespace."
  (declare (character character))
  (not (not (position character *whitespace-chars*))))

(defun trim-whitespace (string)
  (declare (string string))
  (string-trim *whitespace-chars* string))

(defun retrieve-current-serial-numbers ()
  "Retrieve serial numbers of devices currently plugged in."
  (let ((command-results (with-output-to-string (s)
                           (sb-ext:run-program
                            "wmic"
                            '("logicaldisk" "get" "caption,volumeserialnumber")
                            :search t
                            :output s))))
    (the (proper-list (proper-list string))
         (map 'list
              (lambda (s)
                (cl-utilities:split-sequence-if
                 #'whitespacep
                 s
                 :remove-empty-subseqs t))
              (rest (cl-utilities:split-sequence
                     #\Newline
                     (trim-whitespace command-results)
                     :remove-empty-subseqs t))))))

(defun check-serial-numbers (serial-number-list serial-number-table)
  "Checks serial numbers in `serial-number-list' and returns the badge number
and drive letter of the first one that's found in `serial-number-table'."
  (declare ((proper-list string) serial-number-list)
           (hash-table serial-number-table))
  (loop for (drive-letter serial-number) in serial-number-list by #'cdr
        do (when (nth-value 1 (gethash serial-number serial-number-table))
             (return (list :badge-number (gethash serial-number
                                                  serial-number-table)
                           :drive-letter drive-letter)))))

(defun copy-files-from-device (drive-letter destination skip-if-exists &optional location-description)
  "Copy all files from `drive-letter' to `destination'.  If `skip-if-exists' is T,
don't copy files that are already in `destination'.  `location-description' is only
used for output."
  (declare ((or string pathname) drive-letter)
           ((or string pathname) destination))
  (let ((destination (uiop/pathname:ensure-directory-pathname destination)))
    (ensure-directories-exist destination)
    (copy-files (format nil "~a/"
                        (uiop/pathname:ensure-directory-pathname drive-letter))
                destination
                skip-if-exists
                location-description)))

(defun try-copy (copy-function from to skip-if-exists &optional location-description)
  "Attempt to use `copy-function' to copy files from `from' directory to `to' directory.'
If any files fail to copy, try to copy them one more time with the generic copy-files function.
If `skip-if-exists' is T, don't copy files already in `to'.  `location-description' is just
used for output."
  (declare (function copy-function)
           ((or pathname string) from)
           ((or pathname string) to))
  (let ((bad-results (nth-value 1 (funcall copy-function
                                           from
                                           to
                                           skip-if-exists
                                           location-description))))
    (cond (bad-results
           (format t "Failed to copy following files~@[ to ~a~]:~%~{~a~%~}~%Trying again...~%"
                   location-description
                   bad-results)
           (let ((bad-results (nth-value 1 (copy-files bad-results
                                                       to
                                                       skip-if-exists
                                                       location-description))))
             (cond (bad-results
                    (format t "Failed to copy following files~@[ to ~a~]:~%~{~a~%~}
Please remove USB and hold for further review.  Press Enter after USB has been removed.~%"
                            location-description
                            bad-results)
                    (ignore-errors (read-line))
                    (format t *waiting-message*))
                   (t t))))
          (t t))))

(defun import-from-usb (device-ids vault-path viewable-path &optional debug)
  "Check connected USBs for matching ones in `device-ids', and if one is found, copy the files
from it to the `vault-path' and `viewable-path'.  If `debug' is T, output extra information."
  (declare (hash-table device-ids)
           ((or string pathname) vault-path)
           ((or string pathname) viewable-path))
  (when debug
    (format t "Serial numbers of connected devices:~%~s~%~%"
            (retrieve-current-serial-numbers)))
  (let ((device (check-serial-numbers (retrieve-current-serial-numbers)
                                      device-ids))
        (vault-path (uiop/pathname:ensure-directory-pathname vault-path))
        (viewable-path (uiop/pathname:ensure-directory-pathname viewable-path)))
    (when device
      (let ((full-vault-path (format nil "~a/~a"
                                     vault-path
                                     (getf device :badge-number)))
            (full-viewable-path (format nil "~a/~a"
                                        viewable-path
                                        (getf device :badge-number))))
        (unless (try-copy #'copy-files-from-device
                          (getf device :drive-letter)
                          full-viewable-path
                          nil
                          "viewable location")
          (return-from import-from-usb))
        (unless (try-copy #'copy-files
                          full-viewable-path
                          full-vault-path
                          t
                          "vault")
          (return-from import-from-usb))
        (format t "Files copied successfully, removing from USB...~%")
        (cl-fad:walk-directory
         (format nil "~a/" (getf device :drive-letter))
         (lambda (file)
           (unless (position (file-namestring file)
                             *ignore-file-list*
                             :test 'string-equal)
             (uiop/filesystem:delete-file-if-exists file))))
        (format t "Complete, please remove USB and press Enter.~%")
        (ignore-errors (read-line))
        (format t *waiting-message*)))))

(defun clean-old-files (expiration-days directory)
  "Remove files from `directory' that haven't been modified in `expiration-days' days."
  (declare (integer expiration-days)
           ((or pathname string) directory))
  (let ((old-files-found ()))
    (walk-directory
     (uiop/pathname:ensure-directory-pathname directory)
     (lambda (file)
       (when (file-older-than-days-p expiration-days file)
         (setf old-files-found (cons file old-files-found))
         (uiop/filesystem:delete-file-if-exists file))))
    (if old-files-found
        (format t "Deleted the following files that were older than ~d days:~%~{~a~%~}~%"
                expiration-days (reverse old-files-found))
        (format t "No files older than ~d days found.~%"
                expiration-days))))

(defun file-older-than-days-p (days file)
  "Return true if `file' is more than `days' days old."
  (declare (integer days)
           ((or pathname string) file))
  (> (seconds->days (- (get-universal-time)
                       (file-write-date file)))
     days))

(defun seconds->days (seconds)
  "Convert `seconds' to days."
  (declare (integer seconds))
  (/ seconds 60 60 24))

(defun files-equivalent-p (file1 file2)
  "Compare `file1' and `file2', returning T if they're the same."
  (declare ((or string pathname) file1)
           ((or string pathname) file2))
  (with-open-file (input-stream1 file1
                                 :direction :input
                                 :element-type '(unsigned-byte 8))
    (with-open-file (input-stream2 file2
                                   :direction :input
                                   :element-type '(unsigned-byte 8))
      (let* ((buf-size 4096)
             (buf1 (make-array buf-size :element-type (stream-element-type input-stream1)))
             (buf2 (make-array buf-size :element-type (stream-element-type input-stream2)))
             (file-length1 (file-length input-stream1))
             (file-length2 (file-length input-stream2)))
        (if (and (integerp file-length1)
                 (integerp file-length2)
                 (= file-length1 file-length2))
            (loop for pos1 = (read-sequence buf1 input-stream1)
                  for pos2 = (read-sequence buf2 input-stream2)
                  with progress = 0
                  with progress-bar-size = 0
                  do (progn
                       (when (or (not (equalp buf1 buf2))
                                 (not (plusp pos1)))
                         (when (< progress-bar-size *progress-bar-length*)
                           (format t
                                   "~v@{~A~:*~}"
                                   (- *progress-bar-length* progress-bar-size)
                                   "="))
                         (if (not (plusp pos1))
                             (return t)
                             (return nil)))
                       (incf progress buf-size)
                       (when (> (floor (* *progress-bar-length*
                                          (/ progress file-length1)))
                                progress-bar-size)
                         (format t "=")
                         (finish-output)
                         (incf progress-bar-size))))
            (format t "~v@{~A~:*~}" *progress-bar-length* "="))))))
