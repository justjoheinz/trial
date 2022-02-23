#|
 This file is a part of trial
 (c) 2022 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial.animation)

(defclass pose (sequences:sequence standard-object)
  ((joints :initform #() :accessor joints)
   (parents :initform (make-array 0 :element-type '(signed-byte 16)) :accessor parents)))

(defmethod initialize-instance :after ((pose pose) &key size source)
  (cond (source
         (pose<- pose source))
        (size
         (sequences:adjust-sequence pose size))))

(defmethod print-object ((pose pose) stream)
  (print-unreadable-object (pose stream :type T)))

(defun pose<- (target source)
  (let* ((orig-joints (joints source))
         (orig-parents (parents source))
         (size (length orig-joints))
         (joints (joints target))
         (parents (parents target)))
    (let ((old (length joints)))
      (when (< old size)
        (setf (joints target) (setf joints (adjust-array joints size)))
        (setf (parents target) (setf parents (adjust-array parents size)))
        (loop for i from old below size
              do (setf (svref joints i) (transform)))))
    (loop for i from 0 below size
          do (setf (aref parents i) (aref orig-parents i))
             (t<- (aref joints i) (aref orig-joints i)))))

(defun pose= (a b)
  (let ((a-joints (joints a))
        (b-joints (joints b))
        (a-parents (parents a))
        (b-parents (parents b)))
    (and (= (length a-joints) (length b-joints))
         (loop for i from 0 below (length a-joints)
               always (and (= (aref a-parents i) (aref b-parents i))
                           (t= (svref a-joints i) (svref b-joints i)))))))

(defmethod sequences:length ((pose pose))
  (length (joints pose)))

(defmethod sequences:adjust-sequence ((pose pose) length &rest args)
  (declare (ignore args))
  (let ((old (length (joints pose))))
    (setf (joints pose) (adjust-array (joints pose) length))
    (when (< old length)
      (loop for i from old below length
            do (setf (svref (joints pose) i) (transform)))))
  (setf (parents pose) (adjust-array (parents pose) length :initial-element 0))
  pose)

(defmethod sequences:elt ((pose pose) index)
  (svref (joints pose) index))

(defmethod (setf sequences:elt) (transform (pose pose) index)
  (setf (svref (joints pose) index) transform))

(defmethod parent-joint ((pose pose) i)
  (aref (parents pose) i))

(defmethod (setf parent-joint) (value (pose pose) i)
  (setf (aref (parents pose) i) value))

(defmethod global-transform ((pose pose) i)
  (let ((joints (joints pose))
        (parents (parents pose)))
    (let ((base (svref joints i)))
      (loop for parent = (aref parents i) then (aref parents parent)
            while (<= 0 parent)
            do (setf base (t+ (svref joints parent) base)))
      base)))

(defmethod matrix-palette ((pose pose) result)
  (let ((old (length result))
        (new (length (joints pose))))
    (when (< old new)
      (setf result (adjust-array result new))
      (loop for i from old below (length result)
            do (setf (svref result i) (meye 4))))
    (dotimes (i new result)
      (tmat4 (global-transform pose i) (svref result i)))))