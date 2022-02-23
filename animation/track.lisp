#|
 This file is a part of trial
 (c) 2022 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial.animation)

(defstruct (frame
            (:constructor make-frame (time curve)))
  (time 0.0 :type single-float)
  (curve NIL :type (function (single-float) T)))

(defmethod print-object ((frame frame) stream)
  (print-unreadable-object (frame stream :type T)
    (format stream "~a" (frame-time frame))))

(defclass track (sequences:sequence standard-object)
  ((frames :initarg :frames :initform #() :accessor frames)
   (interpolation :initarg :interpolation :initform :linear :accessor interpolation)))

(defmethod initialize-instance :after ((track track) &key times values)
  (setf (frames track) (cons times values)))

(defmethod print-object ((track track) stream)
  (print-unreadable-object (track stream :type T)
    (if (valid-p track)
        (format stream "~a ~a" (start-time track) (end-time track))
        (format stream "INVALID"))))

(defgeneric start-time (track))
(defgeneric end-time (track))
(defgeneric sample (track time loop-p))
(defgeneric find-frame-idx (track time loop-p))

(defmethod (setf frames) ((keyframes cons) (track track))
  (destructuring-bind (times . values) keyframes
    (let ((frames (make-array (length times)))
          (j 0))
      (dotimes (i (length times))
        (setf (aref frames i)
              (make-frame (elt times i)
                          (ecase (interpolation track)
                            (:constant
                             (incf j)
                             (constant (elt values (1- j))))
                            (:linear
                             (incf j)
                             (linear (elt values (1- j)) (elt values j)))
                            (:hermite
                             (incf j 3)
                             (hermite (elt values (- j 2)) (elt values (- j 1))
                                      (elt values (+ j 1)) (elt values (+ j 0))))
                            (:bezier
                             ;; DATA is ordered like this: i0 v0 o0 i1 v1 o1
                             (incf j 3)
                             (bezier (elt values (- j 2)) (elt values (- j 1))
                                     (elt values (+ j 1)) (elt values (+ j 0))))))))
      (setf (frames track) frames))))

(defun fit-to-track (track time loop-p)
  (let ((frames (frames track)))
    (if (<= (length frames) 1)
        0.0
        (let ((start (frame-time (svref frames 0)))
              (end (frame-time (svref frames (1- (length frames))))))
          (if loop-p
              (+ start (mod (- time start) (- end start)))
              (trial:clamp start time end))))))

(defmethod valid-p ((track track))
  (< 1 (length (frames track))))

(defmethod start-time ((track track))
  (frame-time (svref (frames track) 0)))

(defmethod end-time ((track track))
  (frame-time (svref (frames track) (1- (length (frames track))))))

(defmethod sequences:adjust-sequence ((track track) length &rest args)
  (setf (frames track) (apply #'adjust-array (frames track) length args))
  track)

(defmethod sequences:length ((track track))
  (length (frames track)))

(defmethod sequences:elt ((track track) index)
  (svref (frames track) index))

(defmethod (setf sequences:elt) (value (track track) index)
  (setf (svref (frames track) index) value))

(defmethod find-frame-idx ((track track) x loop-p)
  (let ((x (fit-to-track track x loop-p))
        (frames (frames track)))
    (loop for i from 0 below (length frames)
          do (when (<= x (frame-time (svref frames i)))
               (return (1- i))))))

(defmethod sample ((track track) time loop-p)
  (let* ((frames (frames track))
         (i (find-frame-idx track time loop-p))
         (l (svref frames i))
         (r (svref frames (1+ i)))
         (x (/ (- time (frame-time l))
               (- (frame-time r) (frame-time l)))))
    (funcall (frame-curve l) x)))

(defclass transform-track ()
  ((name :initarg :name :initform NIL :accessor trial:name)
   (location :initform (make-instance 'track) :accessor location)
   (scaling :initform (make-instance 'track) :accessor scaling)
   (rotation :initform (make-instance 'track) :accessor rotation)))

(defmethod print-object ((track transform-track) stream)
  (print-unreadable-object (track stream :type T)
    (if (valid-p track)
        (format stream "~s ~a ~a" (trial:name track)
                (start-time track)
                (end-time track))
        (format stream "~s INVALID" (trial:name track)))))

(defmethod start-time ((track transform-track))
  (let ((min most-positive-single-float))
    (flet ((try (track)
             (when (valid-p track)
               (setf min (min min (start-time track))))))
      (try (location track))
      (try (scaling track))
      (try (rotation track))
      (if (= min most-positive-single-float)
          0.0 min))))

(defmethod end-time ((track transform-track))
  (let ((max most-negative-single-float))
    (flet ((try (track)
             (when (valid-p track)
               (setf max (max max (end-time track))))))
      (try (location track))
      (try (scaling track))
      (try (rotation track))
      (if (= max most-negative-single-float)
          0.0 max))))

(defmethod sample-transform ((track transform-track) transform time loop-p)
  (when (< 1 (length (location track)))
    (setf (tlocation transform) (sample (location track) time loop-p)))
  (when (< 1 (length (scaling track)))
    (setf (tscaling transform) (sample (scaling track) time loop-p)))
  (when (< 1 (length (rotation track)))
    (setf (trotation transform) (sample (rotation track) time loop-p))))

(defmethod valid-p ((track transform-track))
  (or (< 1 (length (location track)))
      (< 1 (length (scaling track)))
      (< 1 (length (rotation track)))))