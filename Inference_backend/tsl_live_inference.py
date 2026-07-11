"""
Thai Sign Language Live Webcam Inference.

Uses MediaPipe Pose + Hand landmarkers for feature extraction and LiteRT/TFLite
for real-time sign language gesture recognition.
"""

import json
import os
import sys
import urllib.request

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python
from mediapipe.tasks.python import vision
from PIL import Image, ImageDraw, ImageFont

import tsl_preprocess

# Try importing TFLite (LiteRT) from ai_edge_litert if tensorflow is not available
try:
    import ai_edge_litert.interpreter as litert
except ImportError:
    try:
        import tensorflow.lite as litert
    except ImportError as exc:
        raise ImportError(
            "Please install 'ai-edge-litert' or 'tensorflow'"
        ) from exc

try:
    sys.stdout.reconfigure(encoding="utf-8")
except AttributeError:
    pass

# --- Constants ---
INF_SEQUENCE_LEN = 30
THAI_FONT_PATH = "C:/Windows/Fonts/tahoma.ttf"

# Preprocessing must match training exactly; the training script saves its
# config to TSL_Output/preprocess_config.json (falls back to defaults).
PREPROCESS_CONFIG = tsl_preprocess.load_preprocess_config("./TSL_Output")
FEATURE_DIM = tsl_preprocess.feature_dim(PREPROCESS_CONFIG)
CONFIDENCE_THRESHOLD = PREPROCESS_CONFIG["confidence_threshold"]


def draw_thai_text(
    img: np.ndarray,
    text: str,
    position: tuple[int, int],
    font_path: str = THAI_FONT_PATH,
    font_size: int = 20,
    color: tuple[int, int, int] = (0, 255, 0),
) -> np.ndarray:
    """Helper function to draw Thai text using PIL (OpenCV lacks Thai support)."""
    img_pil = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    draw = ImageDraw.Draw(img_pil)
    try:
        font = ImageFont.truetype(font_path, font_size)
    except Exception:
        font = ImageFont.load_default()

    draw.text(position, text, font=font, fill=color)
    return cv2.cvtColor(np.array(img_pil), cv2.COLOR_RGB2BGR)


def download_models_if_missing():
    """Downloads MediaPipe model tasks if they are not already locally present."""
    models = {
        "hand_landmarker.task": "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task",
        "pose_landmarker_full.task": "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task",
    }
    for name, url in models.items():
        if not os.path.exists(name):
            print(f"Downloading {name}...")
            urllib.request.urlretrieve(url, name)
            print(f"✅ {name} ready.")
        else:
            print(f"✅ {name} already exists.")


def main():
    # --- Load Model and Labels ---
    tflite_model_path = "tsl_lstm_f32.tflite"
    if not os.path.exists(tflite_model_path) and os.path.exists(
        os.path.join("./TSL_Output", tflite_model_path)
    ):
        tflite_model_path = os.path.join("./TSL_Output", tflite_model_path)

    label_map_path = "label_map.json"
    if not os.path.exists(label_map_path) and os.path.exists(
        os.path.join("./TSL_Output", label_map_path)
    ):
        label_map_path = os.path.join("./TSL_Output", label_map_path)

    if not os.path.exists(tflite_model_path):
        raise FileNotFoundError(
            f"Model file not found: {tflite_model_path}. "
            "Please train or copy the model first."
        )

    if not os.path.exists(label_map_path):
        raise FileNotFoundError(
            f"Label map file not found: {label_map_path}. "
            "Please generate or copy label map first."
        )

    # Initialize LiteRT interpreter
    interpreter = litert.Interpreter(model_path=tflite_model_path)
    interpreter.allocate_tensors()
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    # Load label map
    with open(label_map_path, encoding="utf-8") as f:
        label_map_data = json.load(f)
    idx_to_label = {int(v): k for k, v in label_map_data.items()}

    # Find the Idle class index
    idle_idx = next(
        (
            int(v)
            for k, v in label_map_data.items()
            if "ไม่ทำอะไรเลย" in k or "idle" in k.lower()
        ),
        None,
    )

    download_models_if_missing()

    base_options_pose = python.BaseOptions(
        model_asset_path="pose_landmarker_full.task"
    )
    options_pose = vision.PoseLandmarkerOptions(
        base_options=base_options_pose,
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
        min_pose_detection_confidence=0.5,
        min_pose_presence_confidence=0.5,
    )

    base_options_hands = python.BaseOptions(
        model_asset_path="hand_landmarker.task"
    )
    options_hands = vision.HandLandmarkerOptions(
        base_options=base_options_hands,
        running_mode=vision.RunningMode.VIDEO,
        num_hands=2,
        min_hand_detection_confidence=0.5,
        min_hand_presence_confidence=0.5,
    )

    sequence = []

    # Determine camera index
    cam_idx = 1
    if len(sys.argv) > 1:
        try:
            cam_idx = int(sys.argv[1])
        except ValueError:
            pass

    cap = cv2.VideoCapture(cam_idx)
    if not cap.isOpened() and cam_idx != 0:
        print(f"⚠️ Could not open camera {cam_idx}, trying camera 0...")
        cam_idx = 0
        cap = cv2.VideoCapture(cam_idx)

    if not cap.isOpened():
        raise RuntimeError(
            f"Could not open webcam (tried index {cam_idx}). "
            "Please check your camera connection."
        )

    with (
        vision.PoseLandmarker.create_from_options(
            options_pose
        ) as pose_landmarker,
        vision.HandLandmarker.create_from_options(
            options_hands
        ) as hand_landmarker,
    ):
        print(
            f"Live inference started using {os.path.basename(tflite_model_path)}..."
        )
        print("Press 'q' in the video window to quit.")

        frame_idx = 0
        try:
            while cap.isOpened():
                success, frame = cap.read()
                if not success:
                    print("Ignoring empty camera frame.")
                    continue

                h, w, _ = frame.shape
                rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                mp_image = mp.Image(
                    image_format=mp.ImageFormat.SRGB, data=rgb_frame
                )

                timestamp_ms = int(cap.get(cv2.CAP_PROP_POS_MSEC))
                if timestamp_ms <= 0:
                    timestamp_ms = frame_idx * 33
                frame_idx += 1

                pose_results = pose_landmarker.detect_for_video(
                    mp_image, timestamp_ms
                )
                hands_results = hand_landmarker.detect_for_video(
                    mp_image, timestamp_ms
                )

                # --- 1. Pose landmarks (21 features) ---
                pose_kp = np.zeros((7, 3))
                shoulder_mid = np.array([0.5, 0.5, 0.0])
                shoulder_width = 1.0

                if pose_results.pose_landmarks:
                    lms = pose_results.pose_landmarks[0]
                    l_shoulder = np.array([lms[11].x, lms[11].y, lms[11].z])
                    r_shoulder = np.array([lms[12].x, lms[12].y, lms[12].z])

                    shoulder_mid = (l_shoulder + r_shoulder) / 2.0
                    shoulder_width = np.linalg.norm(l_shoulder - r_shoulder)
                    if shoulder_width == 0:
                        shoulder_width = 1.0

                    indices = [0, 11, 12, 13, 14, 15, 16]
                    for idx, mp_idx in enumerate(indices):
                        pose_kp[idx] = [
                            lms[mp_idx].x,
                            lms[mp_idx].y,
                            lms[mp_idx].z,
                        ]
                        # Normalize relative to shoulder mid and scale by width
                        pose_kp[idx] = (
                            pose_kp[idx] - shoulder_mid
                        ) / shoulder_width
                        # Draw on frame
                        cv2.circle(
                            frame,
                            (int(lms[mp_idx].x * w), int(lms[mp_idx].y * h)),
                            5,
                            (0, 0, 255),
                            -1,
                        )

                # --- 2. Hand landmarks (126 features) ---
                left_hand_kp = np.zeros((21, 3))
                right_hand_kp = np.zeros((21, 3))

                if hands_results.hand_landmarks:
                    for h_idx, hand_lms in enumerate(
                        hands_results.hand_landmarks
                    ):
                        handedness = hands_results.handedness[h_idx][
                            0
                        ].category_name

                        temp_kp = np.zeros((21, 3))
                        for i, lm in enumerate(hand_lms):
                            temp_kp[i] = [lm.x, lm.y, lm.z]
                            temp_kp[i] = (
                                temp_kp[i] - shoulder_mid
                            ) / shoulder_width
                            # Draw
                            cv2.circle(
                                frame,
                                (int(lm.x * w), int(lm.y * h)),
                                5,
                                (0, 255, 0),
                                -1,
                            )

                        if handedness == "Left":
                            left_hand_kp = temp_kp
                        else:
                            right_hand_kp = temp_kp

                # Combine position keypoints:
                # [Pose (21) | Left Hand (63) | Right Hand (63)]
                combined_pos = np.concatenate([
                    pose_kp.flatten(),
                    left_hand_kp.flatten(),
                    right_hand_kp.flatten(),
                ])

                sequence.append(combined_pos)
                sequence = sequence[-INF_SEQUENCE_LEN:]

                if len(sequence) == INF_SEQUENCE_LEN:
                    seq_arr = np.array(sequence)  # shape (30, 147)

                    # --- Programmatic Bypass Check for Idle/No Hand ---
                    # 1. Hand Presence Threshold: Check in how many frames
                    # hands are detected
                    hands_present = [np.any(f[21:147] != 0.0) for f in seq_arr]
                    num_frames_with_hands = sum(hands_present)

                    # 2. Hand Motion Threshold: Check standard deviation of
                    # coordinates to detect static hand
                    hands_coords = seq_arr[:, 21:147]
                    has_motion = True
                    if num_frames_with_hands > 0:
                        hand_std = np.std(hands_coords, axis=0)
                        mean_std = (
                            np.mean(hand_std[hands_coords[0] != 0.0])
                            if np.any(hands_coords[0] != 0.0)
                            else 0
                        )
                        if mean_std < 0.005:
                            has_motion = False

                    # If hands are missing in most frames or are completely
                    # static, predict Idle immediately
                    if num_frames_with_hands < 6 or not has_motion:
                        if idle_idx is not None:
                            res = np.zeros(len(idx_to_label))
                            res[idle_idx] = 1.0
                        else:
                            res = np.zeros(len(idx_to_label))
                            res[0] = 1.0
                    else:
                        # Run the TFLite model inference.
                        # Same person-invariant normalization + delta features
                        # as training (config loaded from preprocess_config.json).
                        input_seq = tsl_preprocess.preprocess_sequence(
                            seq_arr, PREPROCESS_CONFIG
                        )

                        input_data = np.expand_dims(
                            input_seq, axis=0
                        ).astype(np.float32)
                        interpreter.set_tensor(
                            input_details[0]["index"], input_data
                        )
                        interpreter.invoke()
                        res = interpreter.get_tensor(
                            output_details[0]["index"]
                        )[0]

                    # Sort indices by probability (most to least)
                    sorted_indices = np.argsort(res)[::-1]

                    lines = []
                    # Reject uncertain input instead of forcing one of the
                    # trained classes (unknown signer/gesture safety net).
                    if res.max() < CONFIDENCE_THRESHOLD:
                        lines.append(
                            f"ไม่แน่ใจ (uncertain, top {res.max()*100:.1f}%)"
                        )
                    for idx in sorted_indices:
                        prob = res[idx]
                        if prob > 0.01:
                            label = idx_to_label.get(idx, f"Label {idx}")
                            lines.append(f"{label}: {prob*100:.1f}%")

                    if lines:
                        status_text = "\n".join(lines)
                        frame = draw_thai_text(
                            frame, status_text, (20, 20), font_size=24
                        )

                cv2.imshow("Thai Sign Language Inference", frame)

                if cv2.waitKey(5) & 0xFF == ord("q"):
                    break

        except Exception as e:
            print(f"\nError during inference loop: {e}")
        finally:
            cap.release()
            cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
