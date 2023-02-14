(in-package #:org.shirakumo.fraf.trial.release)

(defvar *default-build-features*
  '(:trial-optimize-all :cl-opengl-no-masked-traps :cl-opengl-no-check-error
    :cl-mixed-no-restarts :trial-release))

(defmethod build :around (target)
  (with-simple-restart (continue "Treat build as successful")
    (call-next-method)))

(defun build-args ()
  (let ((features (append *default-build-features* (config :build :features))))
    (append (list "--dynamic-space-size" (princ-to-string (config :build :dynamic-space-size))
                  "--eval" (format NIL "(setf *features* (append *features* '~s))" features))
            (config :build :build-arguments)
            (list "--eval" (format NIL "(asdf:make :~a :force T)" (config :system))
                  "--disable-debugger" "--quit"))))

(defmethod build ((target (eql :linux)))
  #+linux (apply #'run (config :build :linux) (build-args))
  #+windows (apply #'run "wsl.exe" (config :build :linux) (build-args)))

(defmethod build ((target (eql :windows)))
  (apply #'run (config :build :windows) (build-args)))

(defmethod build ((target (eql :macos)))
  (apply #'run (config :build :macos) (build-args)))

(defmethod build ((target (eql T)))
  (dolist (target (config :build :targets))
    (build target)))

(defmethod build ((targets cons))
  (dolist (target targets)
    (build target)))

(defmethod build ((target null)))

(defmethod test :around (target)
  (setf (uiop:getenv "TRIAL_QUIT_AFTER_INIT") "true")
  (unwind-protect
       (with-simple-restart (continue "Treat test as successful")
         (call-next-method))
    (setf (uiop:getenv "TRIAL_QUIT_AFTER_INIT") "false")))

(defmethod test ((target (eql :linux)))
  (dolist (file (directory (merge-pathnames "bin/*.run" (asdf:system-source-directory (config :system)))))
    #+linux (run file)
    #+windows (run "wsl.exe" file)))

(defmethod test ((target (eql :windows)))
  (dolist (file (directory (merge-pathnames "bin/*.exe" (asdf:system-source-directory (config :system)))))
    #+windows (run file)
    #-windows (run "wine" file)))

(defmethod test ((target (eql T)))
  (dolist (target (config :build :targets))
    (test target)))

(defmethod test ((targets cons))
  (dolist (target targets)
    (test target)))

(defmethod test ((target null)))
