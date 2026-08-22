from transcribe.engine import DEFAULT_MODEL_REPO, LID_MODEL


def test_release_ships_exactly_one_model():
    assert DEFAULT_MODEL_REPO == "mlx-community/whisper-large-v3-turbo-4bit"


def test_language_detection_uses_whisper_tiny():
    assert LID_MODEL == "mlx-community/whisper-tiny"


def test_release_version():
    import transcribe

    assert transcribe.__version__ == "0.5.0"
