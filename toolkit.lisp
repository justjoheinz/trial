#|
 This file is a part of trial
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)

(defparameter *time-units* #+sbcl 1000000
              #-sbcl internal-time-units-per-second)

(defgeneric finalize (object))

(declaim (inline current-time))
(defun current-time ()
  #+sbcl (let ((usec (nth-value 1 (sb-ext:get-time-of-day))))
           (declare (type (unsigned-byte 31) usec))
           usec)
  #-sbcl (get-internal-real-time))

(defmacro undefmethod (name &rest args)
  (flet ((lambda-keyword-p (symbol)
           (find symbol lambda-list-keywords)))
    (destructuring-bind (qualifiers args) (loop for thing = (pop args)
                                                until (listp thing)
                                                collect thing into qualifiers
                                                finally (return (list qualifiers thing)))
      `(remove-method
        #',name
        (find-method
         #',name
         ',qualifiers
         (mapcar #'find-class
                 ',(loop for arg in args
                         until (lambda-keyword-p arg)
                         collect (if (listp arg) (second arg) T))))))))

(defun executable-directory ()
  (pathname-utils:to-directory
   (or (first (uiop:command-line-arguments))
       *default-pathname-defaults*)))

(defun enlist (item &rest items)
  (if (listp item) item (list* item items)))

(defun unlist (item)
  (if (listp item) (first item) item))

(defun remf* (list &rest keys)
  (loop for (k v) on list by #'cddr
        for x = (member k keys)
        unless x collect k
        unless x collect v))

(defun mkarray (dimensions &rest items)
  (let ((array (make-array dimensions)))
    (loop for i from 0 for item in items
          do (setf (row-major-aref array i) item))
    array))

(defun mktable (test &rest items)
  (let ((table (make-hash-table :test test)))
    (loop for (key val) on items by #'cddr
          do (setf (gethash key table) val))
    table))

(defun mkobject (class &rest items)
  (let ((object (allocate-instance (etypecase class
                                     (standard-class class)
                                     (symbol (find-class class))))))
    (loop for (key val) on items by #'cddr
          do (setf (slot-value object key) val))
    object))

(defun update-slots (object &rest items)
  (loop for (key val) on items by #'cddr
        do (setf (slot-value object key) val))
  object)

(defun one-of (thing &rest options)
  (find thing options))

(define-compiler-macro one-of (thing &rest options)
  (let ((thing-var (gensym "THING")))
    `(let ((,thing-var ,thing))
       (or ,@(loop for option in options
                   collect `(eql ,thing-var ,option))))))

(defun input-source (&optional (stream *query-io*))
  (with-output-to-string (out)
    (loop for in = (read-line stream NIL NIL)
          while (and in (string/= in "EOF"))
          do (write-string in out))))

(defun input-value (&optional (stream *query-io*))
  (multiple-value-list (eval (read stream))))

(defun input-literal (&optional (stream *query-io*))
  (read stream))

(defmacro with-retry-restart ((name report &rest report-args) &body body)
  (let ((tag (gensym "RETRY-TAG"))
        (return (gensym "RETURN"))
        (stream (gensym "STREAM")))
    `(block ,return
       (tagbody
          ,tag (restart-case
                   (return-from ,return
                     (progn ,@body))
                 (,name ()
                   :report (lambda (,stream) (format ,stream ,report ,@report-args))
                   (go ,tag)))))))

(defmacro with-new-value-restart ((place &optional (input 'input-value))
                                  (name report &rest report-args) &body body)
  (let ((tag (gensym "RETRY-TAG"))
        (return (gensym "RETURN"))
        (stream (gensym "STREAM"))
        (value (gensym "VALUE")))
    `(block ,return
       (tagbody
          ,tag (restart-case
                   (return-from ,return
                     (progn ,@body))
                 (,name (,value)
                   :report (lambda (,stream) (format ,stream ,report ,@report-args))
                   :interactive ,input
                   (setf ,place ,value)
                   (go ,tag)))))))

(defmacro with-cleanup-on-failure (cleanup-form &body body)
  (let ((success (gensym "SUCCESS")))
    `(let ((,success NIL))
       (unwind-protect
            (multiple-value-prog1
                (progn
                  ,@body)
              (setf ,success T))
         (unless ,success
           ,cleanup-form)))))

(defun acquire-lock-with-starvation-test (lock &key (warn-time 10) timeout)
  (assert (or (null timeout) (< warn-time timeout)))
  (flet ((do-warn () (v:warn :trial.core "Failed to acquire ~a for ~s seconds. Possible starvation!"
                             lock warn-time)))
    #+sbcl (or (sb-thread:grab-mutex lock :timeout warn-time)
               (do-warn)
               (if timeout
                   (sb-thread:grab-mutex lock :timeout (- timeout warn-time))
                   (sb-thread:grab-mutex lock)))
    #-sbcl (loop with start = (get-universal-time)
                 for time = (- (get-universal-time) start)
                 thereis (bt:acquire-lock lock NIL)
                 do (when (and warn-time (< warn-time time))
                      (setf warn-time NIL)
                      (do-warn))
                    (when (and timeout (< timeout time))
                      (return NIL))
                    (bt:thread-yield))))

(defvar *standalone* NIL)
(defun standalone-error-handler (err)
  (when *standalone*
    (v:error :trial err)
    (v:fatal :trial "Encountered unhandled error in ~a, bailing." (bt:current-thread))
    (if (and (uiop:getenv "TRIAL_DEBUG")
             (string/= "" (uiop:getenv "TRIAL_DEBUG")))
        (invoke-debugger err)
        (deploy:quit))))

(defun standalone-logging-handler ()
  (when *standalone*
    (let ((log (uiop:getenv "TRIAL_LOGFILE")))
      (when (and log (string/= "" log))
        (v:define-pipe ()
          (v:file-faucet :file log))))))

(defun make-thread (name func)
  (bt:make-thread (lambda ()
                    (handler-bind ((error #'standalone-error-handler))
                      (funcall func)))
                  :name name
                  :initial-bindings `((*standard-output* . ,*standard-output*)
                                      (*error-output* . ,*error-output*)
                                      (*trace-output* . ,*trace-output*)
                                      (*context* . NIL))))

(defmacro with-thread ((name) &body body)
  `(make-thread ,name (lambda () ,@body)))

(defun wait-for-thread-exit (thread &key (timeout 1) (interval 0.1))
  (loop for i from 0
        while (bt:thread-alive-p thread)
        do (sleep interval)
           (when (= i (/ timeout interval))
             (restart-case
                 (error "Thread ~s did not exit after ~a s." (bt:thread-name thread) (* i interval))
               (continue ()
                 :report "Continue waiting.")
               (abort ()
                 :report "Kill the thread and exit, risking corrupting the image."
                 (bt:destroy-thread thread)
                 (return))))))

(defmacro with-thread-exit ((thread &key (timeout 1) (interval 0.1)) &body body)
  (let ((thread-g (gensym "THREAD")))
    `(let ((,thread-g ,thread))
       (when (and ,thread-g (bt:thread-alive-p ,thread-g))
         ,@body
         (wait-for-thread-exit ,thread-g :timeout ,timeout :interval ,interval)))))

(defmacro with-error-logging ((&optional (category :trial) (message "") &rest args) &body body)
  (let ((category-g (gensym "CATEGORY")))
    `(let ((,category-g ,category))
       (handler-bind ((error (lambda (err)
                               (v:severe ,category-g "~@[~@? ~]~a" ,message ,@args err)
                               (v:debug ,category-g err))))
         ,@body))))

(defmacro with-timing-report ((level category format &rest args) &body body)
  (let ((run (gensym "RUNTIME"))
        (real (gensym "REALTIME")))
    `(let ((,run (get-internal-run-time))
           (,real (get-internal-real-time)))
       (unwind-protect
            (progn ,@body)
         (v:log ,(intern (string level) :keyword) ,category ,format ,@args
                (/ (- (get-internal-run-time) ,run) INTERNAL-TIME-UNITS-PER-SECOND)
                (/ (- (get-internal-real-time) ,real) INTERNAL-TIME-UNITS-PER-SECOND))))))

(defun insert-index (object list &key (key #'identity) (replace T))
  (flet ((k (value) (funcall key value)))
    (let ((n (k object)))
      (cond ((< n (k (first list)))
             (list* object list))
            (T
             (loop for cons on list
                   do (cond ((= n (k (car cons)))
                             (return (when replace (setf (car cons) object))))
                            ((not (cdr cons))
                             (return (setf (cdr cons) (list object))))
                            ((< (k (car cons)) n (k (cadr cons)))
                             (let ((cell (cons object (cdr cons))))
                               (return (setf (cdr cons) cell))))))
             list)))))

(defun symbol->c-name (symbol)
  (with-output-to-string (out)
    (loop for c across (symbol-name symbol)
          do (case c
               (#\- (write-char #\_ out))
               (T (write-char c out))))))

(defun check-gl-type (thing size &optional unsigned)
  (if unsigned
      (unless (<= 0 thing (expt 2 size))
        (error "~a does not fit within [0,2^~a]." thing size))
      (let ((size (1- size)))
        (unless (<= (- (expt 2 size)) thing (1- (expt 2 size)))
          (error "~a does not fit within [-2^~a,2^~:*~a-1]." thing size)))))

(defun gl-coerce (thing type)
  (ecase type
    ((:double :double-float)
     (float thing 0.0d0))
    ((:float :single-float)
     (float thing 0.0s0))
    ((:int)
     (check-gl-type thing 32)
     (values (round thing)))
    ((:uint :unsigned-int)
     (check-gl-type thing 32 T)
     (values (round thing)))
    ((:char :byte)
     (check-gl-type thing 8)
     (values (round thing)))
    ((:uchar :unsigned-char :unsigned-byte)
     (check-gl-type thing 8 T)
     (values (round thing)))))

(defun check-texture-size (width height)
  (let ((max (gl:get* :max-texture-size)))
    (when (< max (max width height))
      (error "Hardware cannot support a texture of size ~ax~a, max is ~a."
             width height max))))

(defmacro define-enum-check (name &body cases)
  (let ((list (intern (format NIL "*~a-~a*" name '#:list)))
        (func (intern (Format NIL "~a-~a" '#:check name))))
    `(progn (defvar ,list '(,@cases))
            (defun ,func (enum)
              (unless (find enum ,list)
                (error "~a is not a valid ~a. Needs to be one of the following:~%~a"
                       enum ',name ,list))))))

(define-enum-check texture-target
  :texture-1d :texture-2d :texture-3d :texture-1d-array
  :texture-2d-array :texture-rectangle :texture-cube-map :texture-cube-map-array
  :texture-buffer :texture-2d-multisample :texture-2d-multisample-array)

(define-enum-check texture-mag-filter
  :nearest :linear)

(define-enum-check texture-min-filter
  :nearest :linear :nearest-mipmap-nearest :nearest-mipmap-linear
  :linear-mipmap-nearest :linear-mipmap-linear)

(define-enum-check texture-wrapping
  :repeat :mirrored-repeat :clamp-to-edge :clamp-to-border)

(define-enum-check shader-type
  :compute-shader :vertex-shader
  :geometry-shader :fragment-shader
  :tess-control-shader :tess-evaluation-shader)

(define-enum-check vertex-buffer-type
  :array-buffer :atomic-counter-buffer
  :copy-read-buffer :copy-write-buffer
  :dispatch-indirect-buffer :draw-indirect-buffer
  :element-array-buffer :pixel-pack-buffer
  :pixel-unpack-buffer :query-buffer
  :shader-storage-buffer :texture-buffer
  :transform-feedback-buffer :uniform-buffer)

(define-enum-check vertex-buffer-element-type
  :double :float :int :uint :char)

(define-enum-check vertex-buffer-data-usage
  :stream-draw :stream-read :stream-copy :static-draw
  :static-read :static-copy :dynamic-draw :dynamic-read
  :dynamic-copy)

(define-enum-check framebuffer-attachment
  :color-attachment0 :color-attachment1 :color-attachment2 :color-attachment3
  :color-attachment4 :color-attachment5 :color-attachment6 :color-attachment7
  :depth-attachment :stencil-attachment :depth-stencil-attachment)
