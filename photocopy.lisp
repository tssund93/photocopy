(defpackage :photocopy
  (:use :cl
        :cl-fad
        :parser.ini
        :trivial-types)
  (:use :photocopy.app-utils)
  (:export :-main))

(in-package :photocopy)

(defvar *paths* (make-hash-table :test 'equal))

(defun -main (&optional args)
  (format t "~a~%" "I don't do much yet"))

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

(defun populate-paths (paths-table paths-section)
  "Populate `paths-table' hash-table with path info in `paths-section'
that was returned by `get-ini-section'."
  (declare (hash-table paths-table)
           ((proper-list (proper-list property-list)) paths-section))
  (loop for path-entry in paths-section
        do (let* ((path-entry-plist (first path-entry))
                  (badge-number (first (getf path-entry-plist :name)))
                  (path (pathname-as-directory (getf path-entry-plist :value))))
             (setf (gethash badge-number paths-table) path))
        return (the hash-table paths-table)))
