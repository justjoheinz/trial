(in-package #:org.shirakumo.fraf.trial)

(defclass static-mesh (mesh-data)
  ())

(defmethod skinned-p ((mesh static-mesh)) NIL)

(defclass skinned-mesh (mesh-data)
  ((vertex-attributes :initform '(location normal uv joints weights))
   (position-normals :initform (make-array 0 :element-type 'single-float) :accessor position-normals)
   (skinned-p :initarg :skinned-p :initform T :accessor skinned-p)))

(defmethod vertex-attributes append ((data skinned-mesh))
  '(location normal uv joints weights))

(defmethod (setf vertex-data) :after (data (mesh skinned-mesh))
  (let ((vertices (truncate (length data) (vertex-attribute-stride mesh))))
    (setf (position-normals mesh) (adjust-array (position-normals mesh) (* vertices (+ 3 3))
                                                :initial-element 0f0))))

(defmethod cpu-skin ((mesh skinned-mesh) pose)
  (let ((pos-normal (position-normals mesh))
        (vertex-data (vertex-data mesh)))
    (flet ((transform (mat out-i in-i w)
             (let ((vec (vec (aref vertex-data (+ in-i 0))
                             (aref vertex-data (+ in-i 1))
                             (aref vertex-data (+ in-i 2))
                             w)))
               (n*m mat vec)
               (setf (aref pos-normal (+ out-i 0)) (vx vec))
               (setf (aref pos-normal (+ out-i 1)) (vy vec))
               (setf (aref pos-normal (+ out-i 2)) (vz vec)))))
      (loop for i from 0 below (length pos-normal) by (+ 3 3)
            for j from 0 by (+ 3 3 2 4 4)
            for mat = (meye 4)
            do (loop for idx from 0 below 4
                     for joint = (floor (aref vertex-data (+ j idx 3 3 2)))
                     for weight = (aref vertex-data (+ j idx 3 3 2 4))
                     do (nm+ mat (m* (svref pose joint) weight)))
               (transform mat (+ i 0) (+ j 0) 1.0)
               (transform mat (+ i 3) (+ j 3) 0.0)))))

(defmethod make-vertex-array ((mesh skinned-mesh) vao)
  (let ((position-normals (make-instance 'vertex-buffer :buffer-data (position-normals mesh)))
        (stride (vertex-attribute-stride mesh)))
    (loop for i from 0 below (length (vertex-data mesh)) by stride
          for j from 0 below (length (position-normals mesh)) by (+ 3 3)
          do (setf (aref (position-normals mesh) (+ j 0)) (aref (vertex-data mesh) (+ i 0)))
             (setf (aref (position-normals mesh) (+ j 1)) (aref (vertex-data mesh) (+ i 1)))
             (setf (aref (position-normals mesh) (+ j 2)) (aref (vertex-data mesh) (+ i 2)))
             (setf (aref (position-normals mesh) (+ j 3)) (aref (vertex-data mesh) (+ i 3)))
             (setf (aref (position-normals mesh) (+ j 4)) (aref (vertex-data mesh) (+ i 4)))
             (setf (aref (position-normals mesh) (+ j 5)) (aref (vertex-data mesh) (+ i 5))))
    (let ((vao (call-next-method)))
      (setf (elt (bindings vao) 0) `(,position-normals :size 3 :offset 0 :stride 24))
      (setf (elt (bindings vao) 1) `(,position-normals :size 3 :offset 12 :stride 24))
      vao)))

(defmethod update-buffer-data ((vao vertex-array) (mesh skinned-mesh) &key)
  (let ((buffer (caar (bindings vao))))
    (update-buffer-data buffer (position-normals mesh))))

(defmethod reorder ((mesh skinned-mesh) map)
  (let ((data (vertex-data mesh)))
    (loop for i from (+ 3 3 2) below (length data) by (vertex-attribute-stride mesh)
          do (setf (aref data (+ i 0)) (float (gethash (truncate (aref data (+ i 0))) map) 0f0))
             (setf (aref data (+ i 1)) (float (gethash (truncate (aref data (+ i 1))) map) 0f0))
             (setf (aref data (+ i 2)) (float (gethash (truncate (aref data (+ i 2))) map) 0f0))
             (setf (aref data (+ i 3)) (float (gethash (truncate (aref data (+ i 3))) map) 0f0)))
    mesh))
