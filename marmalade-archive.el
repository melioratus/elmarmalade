;;; make package archive files --- -*- lexical-binding: t -*-

;;; Commentary

;; Manage the archive-contents file. The archive-contents is an index
;; of the packages in the repository in list form. Each ELPA client
;; using marmalade downloads the archive-contents to know what
;; packages are available on marmalade.

;; The internal representation of the index is a hash table. The hash
;; is never served directly to an ELPA client though, it is cached to
;; an archive-contents list representation in a file and the file is
;; served.

;; Many archive-contents cache files might exist as the hash table is
;; written to a new file each time it is updated. Proxying techniques
;; are used to ensure that marmalade serves the newest
;; archive-contents file to clients.

;;; Notes

;; The code here isn't cleanly namespaced with marmalade/archive or
;; anything like that. But why should it? it's ridiculous to have to
;; do that all the time with a single package.

;;; Code:

(require 'rx)
(require 'package)
(require 'marmalade-customs)
(require 'dash)

(defun marmalade/archive-file (&optional lisp)
  "Get the marmalade archive file name.

If optional LISP is `t', the LISP version of the file is
returned."
  (let ((base
         (concat
          (file-name-as-directory marmalade-package-store-dir)
          "archive-contents")))
    (if lisp (concat base ".el") base)))

;; Directory root mangling code

(defun marmalade/list-dir (root)
  "EmacsLisp version of package find list dir.

The parent directory of ROOT is stripped off the resulting
files."
  (let* ((root-dir (file-name-as-directory
                    (expand-file-name root)))
         (re (concat "^" (expand-file-name
                          (concat root-dir "..")) "\\(.*\\)"))
         (package-dir-list
          (--filter
           ;; no el files at this level
           (not (string-match-p "\\.el$" it)) 
           (directory-files root-dir t "^[^.].*")))
         (version-dir-list
          (loop for package-dir in package-dir-list
             collect (directory-files package-dir t "^[^.].*"))))
    (--map
     (when (string-match re it) (match-string 1 it))
     (-flatten
      (loop for p in (-flatten version-dir-list)
         collect (directory-files p t "^[^.].*"))))))

(defun marmalade/list-files (root)
  "Turn ROOT into a list of maramalade meta data.

ROOT is present on the filename."
  ;; (split-string (marmalade/list-files-string root) "\n")
  (let ((root-parent
         (expand-file-name
          (concat (file-name-as-directory root) "..")))
        (dir-list (marmalade/list-dir root)))
    (loop for filename in dir-list
       if (string-match
           (concat
            "^.*/\\([A-Za-z0-9-]+\\)/"
            "\\([0-9.]+\\)/"
            "\\([A-Za-z0-9.-]+\\).\\(el\\|tar\\)$")
           filename)
       collect
         (list
          (concat root-parent filename)
          ;; (match-string 1 filename)
          ;; (match-string 2 filename)
          ;; (match-string 3 filename)
          ;; The type
          (match-string 4 filename)))))

(defun marmalade/commentary-handle (buffer)
  "package.el does not handle bad commentary declarations.

People forget to add the ;;; Code marker ending the commentary.
This does a substitute."
  (with-current-buffer buffer
    (goto-char (point-min))
    ;; This is where we could remove the ;; from the start of the
    ;; commentary lines
    (let ((commentary-pos
           (re-search-forward "^;;; Commentary" nil t)))
      (if commentary-pos
          (buffer-substring-no-properties
           (+ commentary-pos 3)
           (- (re-search-forward "^;+ .*\n[ \n]+(" nil t) 2))
          "No commentary."))))

(defun marmalade/package-buffer-info (buffer)
  "Do `package-buffer-info' but with fixes."
  (with-current-buffer buffer
    (let ((pkg-info (package-buffer-info)))
      (unless (save-excursion (re-search-forward "^;;; Code:"  nil t))
        (aset pkg-info 4 (marmalade/commentary-handle (current-buffer))))
      pkg-info)))

(defun marmalade/package-file-info (filename)
  "Wraps `marmalade/package-buffer-info' with FILENAME getting."
  (let ((buffer (let ((enable-local-variables nil))
                  (find-file-noselect filename))))
    (unwind-protect
         (marmalade/package-buffer-info buffer)
      ;; FIXME - We should probably only kill it if we didn't have it
      ;; before
      (kill-buffer buffer))))

(defun marmalade/package-stuff (filename type)
  "Make the FILENAME a package of TYPE.

This reads in the FILENAME.  But it does it safely and it also
kills it.

It returns a cons of `single' or `multi' and "
  (let ((ptype
         (case (intern type)
           (el 'single)
           (tar 'tar))))
    (cons
     ptype
     (case ptype
       (single (marmalade/package-file-info filename))
       (tar (package-tar-file-info filename))))))

(defun marmalade/root->archive (root)
  "For ROOT make an archive list."
  (let ((files-list (marmalade/list-files root)))
    (loop for (filename type) in files-list
       with package-stuff
       do
         (setq package-stuff
               (condition-case err
                   (marmalade/package-stuff filename type)
                 (error nil)))
       if package-stuff
       collect package-stuff)))

(defun marmalade/packages-list->archive-list (packages-list)
  "Turn the list of packages into an archive list."
  ;; elpakit has a version of this
  (loop for (type . package) in packages-list
     collect
       (cons
        (intern (elt package 0)) ; name
        (vector (version-to-list (elt package 3)) ; version list
                (elt package 1) ; requirements
                (elt package 2) ; doc string
                type))))

;; Handle the cache

(defvar marmalade/archive-cache (make-hash-table :test 'equal)
  "The cache of all current packages.")

(defun marmalade/archive-cache-fill (root)
  "Fill the cache by reading the ROOT."
  (let ((typed-package-list (marmalade/root->archive root)))
    (loop
       for (type . package) in typed-package-list
       do (let* ((package-name (elt package 0))
                 (current-package
                  (gethash package-name marmalade/archive-cache)))
            (if current-package
                ;; Put it only if it's a newer version
                (let ((current-version (elt (cdr current-package) 3))
                      (new-version (elt package 3)))
                  (when (version< current-version new-version)
                    (puthash
                     package-name (cons type package)
                     marmalade/archive-cache)))
                ;; Else just put it
                (puthash
                 package-name (cons type package)
                 marmalade/archive-cache))))))

(defun marmalade/cache->package-archive (&optional cache)
  "Turn the cache into the package-archive list.

You can optional specify the CACHE or use the default
`marmalade/archive-cache'.

Returns the Lisp form of the archive which is sent (almost
directly) back to ELPA clients.

If the cache is empty this returns `nil'."
  (marmalade/packages-list->archive-list
   (kvalist->values
    (kvhash->alist (or cache marmalade/archive-cache)))))

(defun marmalade/archive-hash->package-file (filename &optional hash)
  "Save the list of packages HASH as an archive with FILENAME."
  (with-temp-file filename
    (insert
     (format
      "%S"
      (cons 1 (marmalade/cache->package-archive hash))))))

(defun marmalade/archive-hash->cache (&optional hash)
  "Save the current package state (or HASH) in a cache file.

The cache file is generated in `marmalade-archive-dir' with a
plain timestamp.

The `marmalade-archive-dir' is forced to exist by this function."
  (let ((dir (file-name-as-directory marmalade-archive-dir)))
    (make-directory dir t)
    (marmalade/archive-hash->package-file
     (concat dir (format-time-string "%Y%m%d%H%M%S%N" (current-time)))
     hash)))

(defun marmalade-archive-make-cache ()
  "Regenerate the archive and make a cache file."
  (marmalade/archive-cache-fill marmalade-package-store-dir)
  (marmalade/archive-hash->cache))

(defun marmalade/archive-newest ()
  "Return the filename of the newest archive file.

The archive file is the cache of the archive-contents.

The filename is returned with the property `:version' being the
latest version number."
  (let* ((cached-archive
          (car
           (directory-files
            (file-name-as-directory marmalade-archive-dir)
            t "^[0-9]+$"))))
    (string-match ".*/\\([0-9]+\\)$" cached-archive)
    (propertize cached-archive
                :version (match-string 1 cached-archive))))

(defun marmalade/archive-cache->list ()
  "Read the latest archive cache into a list."
  (let* ((archive (marmalade/archive-newest))
         (archive-buf (find-file-noselect archive)))
    (unwind-protect
         (with-current-buffer archive-buf
           (goto-char (point-min))
           ;; Read it in and sort it.
           (read (current-buffer)))
      (kill-buffer archive-buf))))

(defun marmalade/archive-cache->hash (&optional hash)
  "Read the latest archive cache into `marmalade/archive-cache'.

If optional HASH is specified then fill that rather than
`marmalade/archive-cache'.

Returns the filled hash."
  (let* ((lst (marmalade/archive-cache->list))
         ;; The car is the ELPA archive format version number
         (archive (cdr lst))
         ;; The hash
         (archive-hash (kvalist->hash archive)))
    (if (hash-table-p hash)
        (progn
          (maphash
           (lambda (k v) (puthash k v hash))
           archive-hash)
          archive-hash)
        (setq marmalade/archive-cache archive-hash))))

(defconst marmalade-archive-cache-webserver
  (elnode-webserver-handler-maker
   (concat marmalade-archive-dir))
  "A webserver for the directory of archive-contents caches.")

(defun marmalade-archive-contents-handler (httpcon)
  "Handle archive-contents requests.

We return proxy redirect to the correct location which is served
by the `marmalade-archive-cache-webserver'."
  (let* ((latest (marmalade/archive-newest))
         (version (get-text-property 0 :version latest))
         (location (format "/packages/archive-contents/%s" version)))
    (elnode-send-proxy-location httpcon location)))

(defun marmalade-archive-router (httpcon)
  "Route package archive requests.

We deliver the most recent \"archive-contents\" by storing them
by date stamp and selecting the lexicographical top."
  (elnode-hostpath-dispatcher
   httpcon
   `(("^[^/]*//packages/archive-contents$"
      . marmalade-archive-contents-handler)
     ("^[^/]*//packages/archive-contents/\\([0-9]+\\)"
      . ,marmalade-archive-cache-webserver))))


(provide 'marmalade-archive)

;;; marmalade-archive.el ends here
