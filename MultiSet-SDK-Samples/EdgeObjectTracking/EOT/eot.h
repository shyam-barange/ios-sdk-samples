/* eot - Edge Object Tracking. C interface for mobile / Unity.
 *
 * One tracker handle tracks one rigid part. Poses are 4x4 row-major float
 * matrices, body -> colour camera, in metres, OpenCV camera convention
 * (x right, y down, z forward).
 *
 * Typical use:
 *   h = eot_create();
 *   eot_set_color_intrinsics(h, ...);
 *   eot_set_depth_intrinsics(h, ...);             // optional: enables depth
 *   eot_load(h, obj, 1.0f, region_bin, depth_bin, 0, cache_dir);
 *   eot_set_pose(h, start_pose);
 *   eot_start(h, color, EOT_BGR, stride, depth, EOT_DEPTH_U16, dstride);
 *   every frame: eot_step(h, ...same image arguments...); eot_get_pose(h, pose);
 *   eot_destroy(h);
 *
 * Not thread-safe: call all functions for one handle from one thread at a time.
 */
#ifndef EOT_H_
#define EOT_H_

#if defined(_WIN32)
#define EOT_API __declspec(dllexport)
#else
#define EOT_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct eot_handle eot_handle;

enum { EOT_BGR = 0, EOT_RGB = 1, EOT_RGBA = 2, EOT_BGRA = 3 };
/* EOT_DEPTH_U16: 16-bit values times depth_scale = metres.
 * EOT_DEPTH_F32: 32-bit float metres. 0 / non-finite = no measurement. */
enum { EOT_DEPTH_U16 = 0, EOT_DEPTH_F32 = 1 };

EOT_API eot_handle *eot_create(void);
EOT_API void eot_destroy(eot_handle *h);

/* Intrinsics of the images that will be passed in (after any downscaling). */
EOT_API void eot_set_color_intrinsics(eot_handle *h, float fu, float fv,
                                      float ppu, float ppv, int width,
                                      int height);
/* Calling this turns the depth modality on. depth_scale is metres per unit for
 * EOT_DEPTH_U16 input (0.001 for millimetres). */
EOT_API void eot_set_depth_intrinsics(eot_handle *h, float fu, float fv,
                                      float ppu, float ppv, int width,
                                      int height, float depth_scale);
/* Pose of the depth camera in the colour camera frame (default: identity). */
EOT_API void eot_set_depth_to_color(eot_handle *h, const float *pose4x4);

/* Load the part. obj_path: mesh; unit_in_meter: mesh unit (1.0 for metres).
 * region_bin / depth_bin: viewpoint models made by eot_genmodel for this mesh.
 * depth_bin may be NULL when depth is off. model_distance: pass 0 to use the
 * distance stored in the model files; a positive value is checked against it.
 * cache_dir: writable folder. On the first load the model files are copied
 * there, re-stamped for this device's paths; later loads reuse the copies.
 * Reads up to ~150 MB from storage: call it off the UI thread.
 * Returns 0 on success. */
EOT_API int eot_load(eot_handle *h, const char *obj_path, float unit_in_meter,
                     const char *region_bin, const char *depth_bin,
                     float model_distance, const char *cache_dir);

/* Load an object from the single file the model generation service delivers
 * (<objectCode>.bin; the name does not matter). The file is unpacked once into <cache_dir>/object, then loaded
 * as eot_load does; later calls with the same file skip the unpacking. The
 * depth part is only unpacked when depth intrinsics were set. cache_dir must
 * be writable and private to the app; it ends up holding about 300 MB per
 * object. Returns 0, or an error code with the text in eot_last_error. */
EOT_API int eot_load_bundle(eot_handle *h, const char *bundle_path,
                            const char *cache_dir);

EOT_API void eot_set_pose(eot_handle *h, const float *pose4x4);

/* Optional: where the colour camera is, from the device's own motion tracking
 * (ARKit, ARCore), for the frame passed to the next eot_start or eot_step.
 * camera2world: 4x4 row-major, camera -> world, metres, with the camera axes
 * of the poses (x right, y down, z forward in the image as passed); any fixed
 * world frame will do. Given with eot_start and then on every frame, the
 * object is taken to stand still in that world:
 *   - each frame starts from the last pose carried over the camera's own
 *     motion, so moving or turning the phone does not pull the outline off
 *     the object;
 *   - while the object is lost its pose is held where it was last tracked
 *     well in the room, so it is picked up there when it is back in view,
 *     and auto_recover looks there (and at the start pose, also kept in the
 *     room) rather than where it used to be in the picture;
 *   - no colours are learnt from frames where the object is lost.
 * Skip it on a frame whose camera pose is not reliable (AR tracking not
 * normal): that frame is tracked as without it. An object that is moved is
 * still followed, but once lost it is first looked for where it was.
 * Never calling it leaves the tracker exactly as it was. */
EOT_API void eot_set_camera_pose(eot_handle *h, const float *camera2world);
EOT_API void eot_get_pose(eot_handle *h, float *pose4x4);

/* Begin tracking from the pose set with eot_set_pose, using this frame to
 * learn the part / background colours. Returns 0 on success. */
EOT_API int eot_start(eot_handle *h, const unsigned char *color,
                      int color_format, int color_stride, const void *depth,
                      int depth_format, int depth_stride);
/* Track one frame. Returns 0 on success. */
EOT_API int eot_step(eot_handle *h, const unsigned char *color,
                     int color_format, int color_stride, const void *depth,
                     int depth_format, int depth_stride);

/* How well the current pose explains the last frame, 0 to 1: does the
 * silhouette's interior differ in colour from what is just outside it, and
 * does it still look like the object. Higher is better. How high it gets
 * depends on how much the object stands out, so compare it with its own
 * history, or use eot_is_lost. Returns -1 when it cannot be judged: before
 * eot_start, or when the object does not stand out from its surroundings. */
EOT_API float eot_get_quality(eot_handle *h);

/* The same measure as a confidence for showing to a user or acting on: the
 * quality divided by what is usual on this run, limited to 0..1. 1 means "as
 * good as it normally gets". -1 when it cannot be judged. */
EOT_API float eot_get_confidence(eot_handle *h);

/* 1 while the tracker considers the object lost: the quality stayed well
 * below what is usual on this run for several frames. Tracking carries on
 * regardless and eot_get_pose keeps returning its pose. With the option
 * auto_recover=1 the tracker looks for the object itself; otherwise the
 * application decides (hide the overlay, ask the user to re-align and call
 * eot_start again).
 *
 * Quality, confidence and the lost flag are judged from colour: how well the
 * object's colours fill the outline and differ from what surrounds it. They
 * report a pose that has come off the object. They cannot tell the object
 * from another thing of the same colours and a similar outline.
 * A lost object counts as back by itself only after three good frames that
 * also show the whole object at a believable distance, as auto_recover asks
 * of what it finds: an outline cut off by the edge of the picture fits
 * whatever is there.
 * An object that does not stand out from its surroundings (confidence -1)
 * counts as lost only when its outline leaves the picture. Without
 * auto_recover it then stays lost until eot_start. */
EOT_API int eot_is_lost(eot_handle *h);

/* Options, as text. Call before eot_load. Returns 0 if the option is known.
 *   snap_start=1    at eot_start, move the given pose onto the object it
 *                   points at, so that a rough start pose is enough. This
 *                   goes by colour: where the object does not stand out from
 *                   what is around it (a black part in front of other black
 *                   things) the given pose is kept as it is
 * When the object counts as lost:
 *   lost_ratio=0.55  a frame is poor when the quality is below this share of
 *                    the usual level
 *   lost_view=0.6    a frame is also poor when less than this share of the
 *                    object lies inside the picture
 *   lost_after=5     poor frames in a row before the object counts as lost
 * Finding the object again, off by default:
 *   auto_recover=1  while the object is lost, look for it by its colours on
 *                   every third frame and move to it. A pose is only accepted
 *                   if it explains the picture clearly better than the
 *                   current one, has the object's colours inside its outline,
 *                   lies between accept_near (0.4) and accept_far (2.5) model
 *                   distances from the camera and shows the whole object. For
 *                   the next 90 frames the new pose must keep the object's
 *                   colours inside its outline (lost_inside, 0.5), or it
 *                   counts as lost again and the search goes on. So
 *                   tracking resumes when the object comes back into the
 *                   picture; an object that is only partly in view, or far
 *                   away, is not picked up. It can still be fooled by another
 *                   thing with the object's colours, size and outline.
 *                   The pose given at eot_start (the guide the user lined
 *                   up) is always one of the places searched. An object
 *                   that does not stand out by colour (confidence -1) is
 *                   looked for only there: while lost the pose is held at
 *                   the start pose, and tracking resumes once the outline
 *                   there stands out about as well as it did while tracked
 *                   (resume_ratio, 0.85 of the usual contrast) on 3 frames
 *                   in a row. Applications show the start guide while lost.
 * Experimental, off by default:
 *   learn_gate=1    do not learn colours from frames below gate_ratio (0.55)
 *                   of the usual level
 * Other tuning: accept_ratio, accept_margin, accept_inside, lost_inside,
 * corr_iterations,
 * update_iterations, scales, standard_deviations (comma lists), lines_max,
 * learning_rate, learning_rate_f, learning_rate_b. */
EOT_API int eot_set_option(eot_handle *h, const char *name, const char *value);

/* Text of the last error on this handle ("" if none). */
EOT_API const char *eot_last_error(eot_handle *h);
EOT_API const char *eot_version(void);

#ifdef __cplusplus
}
#endif
#endif /* EOT_H_ */
