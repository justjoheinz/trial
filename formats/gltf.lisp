(defpackage #:org.shirakumo.fraf.trial.gltf
  (:use #:cl+trial)
  (:shadow #:asset #:load-image)
  (:local-nicknames
   (#:gltf #:org.shirakumo.fraf.gltf)
   (#:v #:org.shirakumo.verbose))
  (:export
   #:asset
   #:static-gltf-container
   #:static-gltf-entity
   #:animated-gltf-entity))
(in-package #:org.shirakumo.fraf.trial.gltf)

(defun gltf-node-transform (node)
  (let ((matrix (gltf:matrix node))
        (translation (gltf:translation node))
        (scale (gltf:scale node))
        (rotation (gltf:rotation node)))
    (let ((transform (if matrix
                         (tfrom-mat (mat4 matrix))
                         (transform))))
      (when translation
        (vsetf (tlocation transform)
               (aref translation 0)
               (aref translation 1)
               (aref translation 2)))
      (when scale
        (vsetf (tscaling transform)
               (aref scale 0)
               (aref scale 1)
               (aref scale 2)))
      (when rotation
        (qsetf (trotation transform)
               (aref rotation 0)
               (aref rotation 1)
               (aref rotation 2)
               (aref rotation 3)))
      transform)))

(defmethod gltf:construct-element-reader ((element-type (eql :scalar)) (component-type (eql :float)))
  (lambda (ptr)
    (values (cffi:mem-ref ptr :float)
            (cffi:incf-pointer ptr 4))))

(defmethod gltf:construct-element-reader ((element-type (eql :vec2)) (component-type (eql :float)))
  (lambda (ptr)
    (values (vec (cffi:mem-ref ptr :float)
                 (cffi:mem-ref (cffi:incf-pointer ptr 4) :float))
            (cffi:incf-pointer ptr 4))))

(defmethod gltf:construct-element-reader ((element-type (eql :vec3)) (component-type (eql :float)))
  (lambda (ptr)
    (values (vec (cffi:mem-ref ptr :float)
                 (cffi:mem-ref (cffi:incf-pointer ptr 4) :float)
                 (cffi:mem-ref (cffi:incf-pointer ptr 4) :float))
            (cffi:incf-pointer ptr 4))))

(defmethod gltf:construct-element-reader ((element-type (eql :vec4)) (component-type (eql :float)))
  (lambda (ptr)
    (values (quat (cffi:mem-ref ptr :float)
                  (cffi:mem-ref (cffi:incf-pointer ptr 4) :float)
                  (cffi:mem-ref (cffi:incf-pointer ptr 4) :float)
                  (cffi:mem-ref (cffi:incf-pointer ptr 4) :float))
            (cffi:incf-pointer ptr 4))))

(defmethod gltf:construct-element-reader ((element-type (eql :mat4)) (component-type (eql :float)))
  (lambda (ptr)
    (let ((elements (make-array 16 :element-type 'single-float)))
      (dotimes (i (length elements))
        (setf (aref elements i) (cffi:mem-aref ptr :float i)))
      (values (nmtranspose (mat4 elements))
              (cffi:inc-pointer ptr (* 4 16))))))

(defun load-joint-names (gltf)
  (map 'vector #'gltf:name (gltf:nodes gltf)))

(defun load-rest-pose (gltf)
  (let* ((nodes (gltf:nodes gltf))
         (pose (make-instance 'pose :size (length nodes))))
    (loop for i from 0 below (length nodes)
          for node = (aref nodes i)
          do (setf (elt pose i) (gltf-node-transform node))
             (setf (parent-joint pose i) (if (gltf:parent node)
                                             (gltf:idx (gltf:parent node))
                                             -1)))
    (check-consistent pose)
    pose))

(defun load-animation-track (track sampler)
  (setf (interpolation track) (ecase (gltf:interpolation sampler)
                                (:step :constant)
                                (:linear :linear)
                                (:cubicspline :hermite)))
  (setf (frames track) (cons (gltf:input sampler) (gltf:output sampler))))

(defun load-clip (animation)
  (let ((clip (make-instance 'clip :name (gltf:name animation))))
    (loop for channel across (gltf:channels animation)
          for sampler = (svref (gltf:samplers animation) (gltf:sampler channel))
          for track = (find-animation-track clip (gltf:idx (gltf:node (gltf:target channel))) :if-does-not-exist :create)
          do (case (gltf:path (gltf:target channel))
               (:translation (load-animation-track (location track) sampler))
               (:scale (load-animation-track (scaling track) sampler))
               (:rotation (load-animation-track (rotation track) sampler))
               (T (v:warn :trial.gltf "Unknown animation channel target path: ~s on ~s, ignoring."
                        (gltf:path (gltf:target channel)) (gltf:name animation)))))
    (trial::recompute-duration clip)))

(defun load-clips (gltf &optional (table (make-hash-table :test 'equal)))
  (loop for animation across (gltf:animations gltf)
        for clip = (load-clip animation)
        do (setf (gethash (name clip) table) clip))
  table)

(defun load-bind-pose (gltf)
  (let* ((rest-pose (load-rest-pose gltf))
         (world-bind-pose (make-array (length rest-pose))))
    (dotimes (i (length world-bind-pose))
      (setf (svref world-bind-pose i) (global-transform rest-pose i)))
    (loop for skin across (gltf:skins gltf)
          for joints = (gltf:joints skin)
          for acc = (gltf:inverse-bind-matrices skin)
          do (loop for i from 0 below (length joints)
                   for inv-bind-matrix = (elt acc i)
                   do (setf (aref world-bind-pose (gltf:idx (svref joints i)))
                            (tfrom-mat (minv inv-bind-matrix)))))
    (let ((bind-pose rest-pose))
      (loop for i from 0 below (length world-bind-pose)
            for current = (svref world-bind-pose i)
            for p = (parent-joint bind-pose i)
            do (setf (elt bind-pose i)
                     (if (<= 0 p)
                         (t+ (tinv (svref world-bind-pose p)) current)
                         current)))
      (check-consistent bind-pose)
      bind-pose)))

(defun load-skeleton (gltf)
  (make-instance 'skeleton :rest-pose (load-rest-pose gltf)
                           :bind-pose (load-bind-pose gltf)
                           :joint-names (load-joint-names gltf)))

(defun gltf-attribute-to-native-attribute (attribute)
  (case attribute
    (:position 'location)
    (:normal 'normal)
    (:tangent 'tangent)
    (:texcoord_0 'uv)
    (:texcoord_1 'uv-1)
    (:texcoord_2 'uv-2)
    (:texcoord_3 'uv-3)
    (:joints_0 'joints)
    (:joints_1 'joints-1)
    (:joints_2 'joints-2)
    (:joints_3 'joints-3)
    (:weights_0 'weights)
    (:weights_1 'weights-1)
    (:weights_2 'weights-2)
    (:weights_3 'weights-3)))

(defun load-vertex-attribute (mesh attribute accessor skin)
  (let ((data (vertex-data mesh))
        (stride (vertex-attribute-stride mesh))
        (offset (vertex-attribute-offset attribute mesh)))
    (when (< (length data) (length accessor))
      (setf data (adjust-array data (* (length accessor) stride) :element-type 'single-float))
      (setf (vertex-data mesh) data))
    (case (vertex-attribute-category attribute)
      (joints
       (flet ((map-joint (joint)
                (float (max 0 (gltf:idx (svref (gltf:joints skin) joint))) 0f0)))
         (loop for i from 0 below (length accessor)
               for el = (elt accessor i)
               do (setf (aref data (+ (* i stride) offset 0)) (map-joint (aref el 0)))
                  (setf (aref data (+ (* i stride) offset 1)) (map-joint (aref el 1)))
                  (setf (aref data (+ (* i stride) offset 2)) (map-joint (aref el 2)))
                  (setf (aref data (+ (* i stride) offset 3)) (map-joint (aref el 3))))))
      (uv
       (loop for i from 0 below (length accessor)
             for el = (elt accessor i)
             do (setf (aref data (+ (* i stride) offset 0)) (vx2 el))
                (setf (aref data (+ (* i stride) offset 1)) (- 1.0 (vy2 el)))))
      (T
       (ecase (vertex-attribute-size attribute)
         (1
          (loop for i from 0 below (length accessor)
                for el = (elt accessor i)
                do (setf (aref data (+ (* i stride) offset)) (float el 0f0))))
         (2
          (loop for i from 0 below (length accessor)
                for el = (elt accessor i)
                do (setf (aref data (+ (* i stride) offset 0)) (vx2 el))
                   (setf (aref data (+ (* i stride) offset 1)) (vy2 el))))
         (3
          (loop for i from 0 below (length accessor)
                for el = (elt accessor i)
                do (setf (aref data (+ (* i stride) offset 0)) (vx3 el))
                   (setf (aref data (+ (* i stride) offset 1)) (vy3 el))
                   (setf (aref data (+ (* i stride) offset 2)) (vz3 el))))
         (4
          (loop for i from 0 below (length accessor)
                for el = (elt accessor i)
                do (setf (aref data (+ (* i stride) offset 0)) (qx el))
                   (setf (aref data (+ (* i stride) offset 1)) (qy el))
                   (setf (aref data (+ (* i stride) offset 2)) (qz el))
                   (setf (aref data (+ (* i stride) offset 3)) (qw el)))))))))

(defmethod org.shirakumo.memory-regions:call-with-memory-region ((function function) (accessor gltf:accessor) &key (start 0))
  (let ((region (org.shirakumo.memory-regions:memory-region
                 (cffi:inc-pointer (gltf:start accessor) start)
                 (* (gltf:size accessor) (gltf:byte-stride accessor)))))
    (declare (dynamic-extent region))
    (funcall function region)))

(defun load-mesh (primitive skin name)
  (let* ((attributes (sort (loop for attribute being the hash-keys of (gltf:attributes primitive)
                                 for native = (gltf-attribute-to-native-attribute attribute)
                                 when native collect native)
                           #'vertex-attribute<))
         (mesh (make-instance (if skin 'skinned-mesh 'static-mesh)
                              :name name :vertex-form (gltf:mode primitive)
                              :vertex-attributes attributes)))
    (when (gltf:material primitive)
      (setf (material mesh) (or (gltf:name (gltf:material primitive))
                                (gltf:idx (gltf:material primitive)))))
    (loop for attribute being the hash-keys of (gltf:attributes primitive) using (hash-value accessor)
          for native = (gltf-attribute-to-native-attribute attribute)
          do (when (member native attributes)
               (load-vertex-attribute mesh native accessor skin)))
    (when (gltf:indices primitive)
      (let* ((accessor (gltf:indices primitive))
             (indexes (make-array (length accessor) :element-type (ecase (gltf:component-type accessor)
                                                                    (:uint8  '(unsigned-byte 8))
                                                                    (:uint16 '(unsigned-byte 16))
                                                                    (:uint32 '(unsigned-byte 32))))))
        (setf (index-data mesh) indexes)
        (org.shirakumo.memory-regions:replace indexes accessor)))
    mesh))

(defun load-meshes (gltf)
  (let ((meshes (make-array 0 :adjustable T :fill-pointer T)))
    (loop for node across (gltf:nodes gltf)
          for skin = (gltf:skin node)
          do (when (gltf:mesh node)
               (let ((base-name (or (gltf:name (gltf:mesh node)) (gltf:idx (gltf:mesh node))))
                     (primitives (gltf:primitives (gltf:mesh node))))
                 (case (length primitives)
                   (0)
                   (1 (vector-push-extend (load-mesh (aref primitives 0) skin base-name) meshes))
                   (T (loop for i from 0 below (length primitives)
                            for primitive = (aref primitives i)
                            do (vector-push-extend (load-mesh primitive skin (cons base-name i)) meshes)))))))
    meshes))

(defun load-image (asset texinfo)
  (when texinfo
    (let* ((texture (gltf:texture texinfo))
           (sampler (gltf:sampler texture))
           (image (gltf:source texture))
           (name (or (gltf:name image)
                     (gltf:uri image)
                     (gltf:name (gltf:buffer-view image))
                     (format NIL "image-~d" (gltf:idx image)))))
      (generate-resources 'image-loader (if (gltf:uri image)
                                            (gltf:path image)
                                            (memory-region (gltf:start (gltf:buffer-view image))
                                                           (gltf:byte-length (gltf:buffer-view image))))
                          :type (or (gltf:mime-type image) T)
                          :resource (resource asset name)
                          :mag-filter (if sampler (gltf:mag-filter sampler) :linear)
                          :min-filter (if sampler (gltf:min-filter sampler) :linear)
                          :wrapping (list (if sampler (gltf:wrap-s sampler) :clamp-to-edge)
                                          (if sampler (gltf:wrap-t sampler) :clamp-to-edge)
                                          (if sampler (gltf:wrap-t sampler) :clamp-to-edge))))))

(defun load-materials (gltf asset)
  (flet ((to-vec (array)
           (ecase (length array)
             (2 (vec (aref array 0) (aref array 1)))
             (3 (vec (aref array 0) (aref array 1) (aref array 2)))
             (4 (vec (aref array 0) (aref array 1) (aref array 2) (aref array 3))))))
    (loop for material across (gltf:materials gltf)
          for pbr = (gltf:pbr material)
          for name = (or (gltf:name material) (gltf:idx material))
          for mr = (load-image asset (gltf:metallic-roughness pbr))
          do (when mr (setf (trial::swizzle mr) '(:b :g :r :a)))
             (trial:update-material
              name 'trial:pbr-material
              :albedo-texture (load-image asset (gltf:albedo pbr))
              :metal-rough-texture mr
              :occlusion-texture (load-image asset (gltf:occlusion-texture material))
              :emissive-texture (load-image asset (gltf:emissive-texture material))
              :normal-texture (load-image asset (gltf:normal-texture material))
              :albedo-factor (to-vec (gltf:albedo-factor pbr))
              :metallic-factor (float (gltf:metallic-factor pbr) 0f0)
              :roughness-factor (float (gltf:roughness-factor pbr) 0f0)
              :emissive-factor (to-vec (gltf:emissive-factor material))
              :occlusion-factor (if (gltf:occlusion-texture material) 1.0 0.0)
              :alpha-cutoff (float (gltf:alpha-cutoff material) 0f0)))))

(defun load-light (light)
  (flet ((make (type &rest initargs)
           (apply #'make-instance type
                  ;; FIXME: intensity is not correctly handled here.
                  :color (v* (gltf:color light) (gltf:intensity light))
                  initargs)))
    (ecase (gltf:kind light)
      (:directional
       (make 'trial:directional-light :direction (vec 0 0 -1)))
      (:point
       (make 'trial:point-light :linear-attenuation (or (gltf:range light) 0.0)))
      (:spot
       (make 'trial:spot-light :direction (vec 0 0 -1)
                               :linear-attenuation (or (gltf:range light) 0.0)
                               :inner-radius (gltf:inner-angle light)
                               :outer-radius (gltf:outer-angle light))))))

(defun load-environment-light (light)
  (make-instance 'trial:environment-light
                 :color (vec (gltf:intensity light) (gltf:intensity light) (gltf:intensity light))
                 :irradiance-map (trial:implement!)
                 :environment-map (trial:implement!)))

(defclass static-gltf-container (transformed-entity array-container)
  ())

(define-shader-entity static-gltf-entity (trial::multi-mesh-entity trial::per-array-material-renderable static-gltf-container)
  ())

(define-shader-entity animated-gltf-entity (trial::multi-mesh-entity trial::per-array-material-renderable static-gltf-container )
  ())

(defclass asset (file-input-asset
                 multi-resource-asset
                 animation-asset
                 ;; KLUDGE: this should not be necessary if we can figure out the loading correctly
                 trial::full-load-asset)
  ((scenes :initform (make-hash-table :test 'equal) :accessor scenes)))

(defmethod generate-resources ((asset asset) input &key load-scene)
  (gltf:with-gltf (gltf input)
    (let ((meshes (meshes asset))
          (clips (clips asset)))
      (load-materials gltf asset)
      (loop for mesh across (load-meshes gltf)
            do (setf (gethash (name mesh) meshes) mesh)
               (trial::make-vertex-array mesh (resource asset (name mesh))))
      ;; Patch up
      (when (loop for mesh being the hash-values of meshes
                  thereis (skinned-p mesh))
        (setf (skeleton asset) (load-skeleton gltf))
        (load-clips gltf clips)
        (let ((map (make-hash-table :test 'eql)))
          (trial::reorder (skeleton asset) map)
          (loop for clip being the hash-values of (clips asset)
                do (trial::reorder clip map))
          (loop for mesh being the hash-values of (meshes asset)
                do (trial::reorder mesh map))))
      ;; Construct scene graphs
      (labels ((construct (node)
                 (cond ((gltf:mesh node)
                        (let ((mesh-name (or (gltf:name (gltf:mesh node)) (gltf:idx (gltf:mesh node)))))
                          (make-instance (etypecase (or (gethash mesh-name meshes)
                                                        (gethash (cons mesh-name 0) meshes))
                                           (static-mesh 'static-gltf-entity)
                                           (skinned-mesh 'animated-gltf-entity))
                                         :transform (gltf-node-transform node)
                                         :name (gltf:name node)
                                         :asset asset
                                         :mesh mesh-name)))
                       (T
                        (make-instance 'static-gltf-container :transform (gltf-node-transform node)
                                                              :name (gltf:name node)))))
               (recurse (children container)
                 (loop for node across children
                       for child = (construct node)
                       do (recurse (gltf:children node) child)
                          (loop for light across (gltf:lights node)
                                do (enter (load-light light) child))
                          (enter child container))))
        (loop for node across (gltf:scenes gltf)
              for scene = (make-instance 'static-gltf-container :name (gltf:name node))
              do (setf (gethash (gltf:name node) (scenes asset)) scene)
                 (when (gltf:light node)
                   (enter (load-environment-light (gltf:light node)) scene))
                 (recurse (gltf:nodes node) scene)))
      ;; Enter it.
      (flet ((load-scene (scene)
               (enter scene (scene +main+))))
        (etypecase load-scene
          (string
           (load-scene (or (gethash load-scene (scenes asset))
                           (error "No scene named~%  ~s~%in~%  ~a" load-scene asset))))
          ((eql T)
           (loop for scene being the hash-values of (scenes asset)
                 do (load-scene scene)))
          (null))))))
