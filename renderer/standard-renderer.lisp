(in-package #:org.shirakumo.fraf.trial)

(define-gl-struct standard-environment-information
  (view-matrix :mat4)
  (inv-view-matrix :mat4)
  (projection-matrix :mat4)
  (inv-projection-matrix :mat4)
  (view-size :uvec2 :accessor view-size)
  (camera-position :vec3 :accessor location)
  (near-plane :float :accessor near-plane)
  (far-plane :float :accessor far-plane)
  (tt :float :accessor tt)
  (dt :float :accessor dt)
  (fdt :float :accessor fdt)
  (gamma :float :initform 2.2 :accessor gamma))

(define-asset (trial standard-environment-information) uniform-block
    'standard-environment-information
  :binding NIL)

(define-shader-pass standard-render-pass (per-object-pass)
  ((color :port-type output :texspec (:internal-format :rgba32f) :attachment :color-attachment0 :reader color)
   (normal :port-type output :texspec (:internal-format :rgb16f) :attachment :color-attachment1 :reader normal)
   (depth :port-type output :attachment :depth-stencil-attachment :reader depth)
   (frame-start :initform 0d0 :accessor frame-start)
   (material-block :buffer T :reader material-block)
   (light-block :buffer T :reader light-block)
   (allocated-textures :initform (make-lru-cache 16 'eq) :accessor allocated-textures)
   (allocated-materials :accessor allocated-materials)
   (allocated-lights :accessor allocated-lights))
  (:buffers (trial standard-environment-information))
  (:shader-file (trial "standard-render-pass.glsl")))

(defmethod initialize-instance :after ((pass standard-render-pass) &key (max-lights 128) (max-materials 64))
  (setf (allocated-materials pass) (make-lru-cache max-materials))
  (setf (allocated-lights pass) (make-lru-cache max-lights))
  (setf (slot-value pass 'material-block) (make-instance 'uniform-buffer :binding NIL :struct (make-instance (material-block-type pass) :size max-materials)))
  (setf (slot-value pass 'light-block) (make-instance 'uniform-buffer :binding NIL :struct (make-instance 'standard-light-block :size max-lights))))

(defmethod shared-initialize :after ((pass standard-render-pass) slots &key)
  (let ((max-textures (max 16 (if *context* (gl:get-integer :max-texture-image-units) 0))))
    (dolist (port (flow:ports pass))
      (typecase port
        (texture-port
         (setf max-textures (min max-textures (unit-id port))))))
    (lru-cache-resize (allocated-textures pass) max-textures)))

(defmethod make-pass-shader-program ((pass standard-render-pass) (object renderable))
  (if (typep object 'standard-renderable)
      (call-next-method)
      (make-shader-program object)))

(defmethod make-pass-shader-program ((pass standard-render-pass) (class shader-entity-class))
  (if (c2mop:subclassp class (find-class 'standard-renderable))
      (call-next-method)
      (make-shader-program class)))

(defmethod clear :after ((pass standard-render-pass))
  (lru-cache-clear (allocated-textures pass))
  (lru-cache-clear (allocated-materials pass))
  (lru-cache-clear (allocated-lights pass)))

(defgeneric material-block-type (standard-render-pass))

(define-handler (standard-render-pass tick) (tt dt)
  (with-buffer-tx (buffer (// 'trial 'standard-environment-information) :update NIL)
    (setf (slot-value buffer 'tt) (float tt 0f0))
    (setf (slot-value buffer 'dt) (float dt 0f0))))

(defmethod render :before ((pass standard-render-pass) target)
  (let* ((frame-time (current-time))
         (old-time (shiftf (frame-start pass) frame-time))
         (fdt (- frame-time old-time))
         (camera (camera pass))
         (tmp-mat (mat4)) (tmp-vec (vec2)))
    (declare (dynamic-extent tmp-mat tmp-vec))
    (with-buffer-tx (buffer (// 'trial 'standard-environment-information))
      (setf (slot-value buffer 'view-matrix) (view-matrix))
      (setf (slot-value buffer 'inv-view-matrix) (!minv tmp-mat (view-matrix)))
      (setf (slot-value buffer 'projection-matrix) (projection-matrix))
      (setf (slot-value buffer 'inv-projection-matrix) (!minv tmp-mat (projection-matrix)))
      (setf (slot-value buffer 'view-size) (vsetf tmp-vec (width (framebuffer pass)) (height (framebuffer pass))))
      (setf (slot-value buffer 'camera-position) (global-location camera))
      (setf (slot-value buffer 'near-plane) (near-plane camera))
      (setf (slot-value buffer 'far-plane) (far-plane camera))
      (setf (slot-value buffer 'fdt) (float fdt 0f0))
      (setf (slot-value buffer 'gamma) (setting :display :gamma)))))

(defmethod bind-textures ((pass standard-render-pass))
  (call-next-method)
  (do-lru-cache (texture id (allocated-textures pass))
    (gl:active-texture id)
    (gl:bind-texture (target texture) (gl-name texture))))

(defmethod enable ((texture texture) (pass standard-render-pass))
  ;; KLUDGE: We effectively disable the cache here BECAUSE the texture binds are
  ;;         shared between standard-renderables and non, and the latter can
  ;;         thrash our bindings without our noticing. I'm not sure what the best
  ;;         solution is here at the moment, but this less-performant hack at
  ;;         least makes things work for now.
  (let ((id (or (lru-cache-push texture (allocated-textures pass))
                (lru-cache-id texture (allocated-textures pass)))))
    (when id
      (gl:active-texture id)
      (gl:bind-texture (target texture) (gl-name texture)))
    id))

(defmethod disable ((texture texture) (pass standard-render-pass))
  (lru-cache-pop texture (allocated-textures pass)))

(defmethod local-id ((texture texture) (pass standard-render-pass))
  (lru-cache-id texture (allocated-textures pass)))

(defmethod enable ((light light) (pass standard-render-pass))
  (let ((id (lru-cache-push light (allocated-lights pass))))
    (when id
      (with-buffer-tx (struct (light-block pass))
        (transfer-to (aref (slot-value struct 'lights) id) light)
        (setf (light-count struct) (max (light-count struct) (1+ id)))))))

(defmethod disable ((light light) (pass standard-render-pass))
  (let ((id (lru-cache-pop light (allocated-lights pass))))
    (when id
      (with-buffer-tx (struct (light-block pass))
        (setf (light-type (aref (lights struct) id)) 0)
        (loop for i downfrom (light-count struct) above 0
              do (when (active-p (aref (lights struct) i))
                   (setf (light-count struct) (1+ i))
                   (return))
              finally (setf (light-count struct) 0))))))

(defmethod local-id ((light light) (pass standard-render-pass))
  (lru-cache-id light (allocated-lights pass)))

(defmethod notice-update ((light light) (pass standard-render-pass))
  (let ((id (lru-cache-id light (allocated-lights pass))))
    (when id
      (with-buffer-tx (struct (light-block pass))
        (transfer-to (aref (slot-value struct 'lights) id) light)))))

(defmethod enable ((material material) (pass standard-render-pass))
  (let ((id (lru-cache-push material (allocated-materials pass))))
    (when id
      (with-buffer-tx (struct (material-block pass))
        (transfer-to (aref (slot-value struct 'materials) id) material)))
    (loop for texture across (textures material)
          do (enable texture pass))))

(defmethod disable ((material material) (pass standard-render-pass))
  (lru-cache-pop material (allocated-materials pass)))

(defmethod local-id ((material material) (pass standard-render-pass))
  (lru-cache-id material (allocated-materials pass)))

(defmethod notice-update ((material material) (pass standard-render-pass))
  (let ((id (lru-cache-id material (allocated-materials pass))))
    (when id
      (with-buffer-tx (struct (material-block pass))
        (transfer-to (aref (slot-value struct 'materials) id) material)))))

(defmethod render-with ((pass standard-render-pass) (material material) program)
  (error "Unsupported material~%  ~s~%for pass~%  ~s"
         material pass))

(define-shader-entity standard-renderable (renderable)
  (vertex-array ;; Backwards compatibility stub
   (vertex-arrays :initarg :vertex-arrays :initform #() :accessor vertex-arrays))
  (:shader-file (trial "standard-renderable.glsl"))
  (:inhibit-shaders (shader-entity :fragment-shader)))

(defmethod shared-initialize :after ((renderable standard-renderable) slots &key vertex-array)
  (cond (vertex-array
         (setf (vertex-array renderable) vertex-array))
        ((slot-boundp renderable 'vertex-array)
         (setf (vertex-array renderable) (slot-value renderable 'vertex-array)))))

(defmethod stage :after ((renderable standard-renderable) (area staging-area))
  (loop for vao across (vertex-arrays renderable)
        do (stage vao area)))

(define-transfer standard-renderable vertex-arrays)

(defmethod render ((renderable standard-renderable) (program shader-program))
  (declare (optimize speed))
  (setf (uniform program "model_matrix") (model-matrix))
  (let ((inv (mat4)))
    (declare (dynamic-extent inv))
    (!minv inv (model-matrix))
    (setf (uniform program "inv_model_matrix") inv))
  (loop for vao across (vertex-arrays renderable)
        do (render vao program)))

(defmethod vertex-array ((renderable standard-renderable))
  (when (< 0 (length (vertex-arrays renderable)))
    (aref (vertex-arrays renderable) 0)))

(defmethod (setf vertex-array) ((resource resource) (renderable standard-renderable))
  (setf (vertex-arrays renderable) (vector resource)))

(define-shader-entity standard-animated-renderable (standard-renderable animated-entity)
  ()
  (:shader-file (trial "standard-animated-renderable.glsl"))
  (:inhibit-shaders (animated-entity :vertex-shader)
                    (standard-renderable :vertex-shader)))

(defmethod render-with :before ((pass standard-render-pass) (renderable standard-animated-renderable) (program shader-program))
  (setf (uniform program "pose") (enable (palette-texture renderable) pass)))

(define-shader-entity single-material-renderable (standard-renderable)
  ((material :initarg :material :accessor material)))

(defmethod stage :after ((renderable single-material-renderable) (area staging-area))
  (when (material renderable)
    (stage (material renderable) area)))

(define-transfer single-material-renderable material)

(defmethod render-with :before ((pass standard-render-pass) (object single-material-renderable) program)
  (prepare-pass-program pass program)
  (when (material object)
    (render-with pass (material object) program)))

(define-shader-entity per-array-material-renderable (standard-renderable)
  ((materials :initarg :materials :initform #() :accessor materials)))

(defmethod stage :after ((renderable per-array-material-renderable) (area staging-area))
  (loop for material across (materials renderable)
        do (stage material area)))

(define-transfer per-array-material-renderable materials)

(defmethod render-with :before ((pass standard-render-pass) (renderable per-array-material-renderable) program)
  (prepare-pass-program pass program))

(defmethod render-with ((pass standard-render-pass) (renderable per-array-material-renderable) program)
  ;; KLUDGE: we can't do this in RENDER as we don't have access to the PASS variable, which we
  ;;         need to set the per-vao material. This will break user expectations, as the RENDER
  ;;         primary on the renderable is not invoked. Not sure how to fix this issue.
  (setf (uniform program "model_matrix") (model-matrix))
  (let ((inv (mat4)))
    (declare (dynamic-extent inv))
    (!minv inv (model-matrix))
    (setf (uniform program "inv_model_matrix") inv))
  (loop for vao across (vertex-arrays renderable)
        for material across (materials renderable)
        do (render-with pass material program)
           (render vao program)))

(defmethod (setf mesh) :after ((meshes cons) (renderable per-array-material-renderable))
  (let ((arrays (make-array (length meshes))))
    (map-into arrays (lambda (m) (or (material m) (material 'none))) meshes)
    (setf (materials renderable) arrays)))

(define-shader-pass light-cache-render-pass (standard-render-pass)
  ((light-cache :initform (org.shirakumo.fraf.trial.space.kd-tree:make-kd-tree) :reader light-cache)
   (light-cache-dirty-p :initform T :accessor light-cache-dirty-p)
   (light-cache-location :initform (vec 0 0 0) :reader light-cache-location)
   (light-cache-distance-threshold :initform 10.0 :accessor light-cache-distance-threshold)
   (ambient-light :initform NIL :accessor ambient-light)))

(defmethod object-renderable-p ((light light) (pass light-cache-render-pass)) T)

(defmethod clear :after ((pass light-cache-render-pass))
  (3ds:clear (light-cache pass)))

(defmethod enter ((light light) (pass light-cache-render-pass))
  (3ds:enter light (light-cache pass))
  (setf (light-cache-dirty-p pass) T))

(defmethod leave ((light light) (pass light-cache-render-pass))
  (3ds:leave light (light-cache pass))
  (setf (light-cache-dirty-p pass) T))

(defmethod enter ((light ambient-light) (pass light-cache-render-pass))
  (setf (ambient-light pass) light)
  (setf (light-cache-dirty-p pass) T))

(defmethod leave ((light ambient-light) (pass light-cache-render-pass))
  (when (eq light (ambient-light pass))
    (setf (ambient-light pass) NIL)
    (disable light pass)))

(define-handler ((pass light-cache-render-pass) tick :before) ()
  (when (<= (light-cache-distance-threshold pass)
            (vsqrdistance (focal-point (camera pass)) (light-cache-location pass)))
    (setf (light-cache-dirty-p pass) T)))

(defmethod render :before ((pass light-cache-render-pass) target)
  (when (light-cache-dirty-p pass)
    (let ((location (v<- (light-cache-location pass) (focal-point (camera pass))))
          (size (1- (lru-cache-size (allocated-lights pass)))))
      (multiple-value-bind (nearest count) (org.shirakumo.fraf.trial.space.kd-tree:kd-tree-k-nearest
                                            size location (light-cache pass) :test #'active-p)
        (dotimes (i count)
          (enable (aref nearest i) pass)))
      (when (ambient-light pass)
        (enable (ambient-light pass) pass)))
    (setf (light-cache-dirty-p pass) NIL)))

;; FIXME: how do we know when lights moved or de/activated so we can update?

(define-shader-entity basic-entity (multi-mesh-entity per-array-material-renderable distance-lod-entity basic-node)
  ())

(define-shader-entity basic-physics-entity (rigidbody basic-entity)
  ())

(define-shader-entity basic-animated-entity (multi-mesh-entity standard-animated-renderable per-array-material-renderable distance-lod-entity basic-node)
  ())

(define-shader-entity animated-physics-entity (rigidbody basic-animated-entity)
  ())
