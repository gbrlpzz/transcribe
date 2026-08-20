from transcribe.engine import DEFAULT_MODEL, MODELS


def test_release_exposes_only_tested_turbo_profile():
    assert set(MODELS) == {"turbo"}
    assert DEFAULT_MODEL == "mlx-community/whisper-turbo"
    assert MODELS["turbo"]["mlx"] == DEFAULT_MODEL


def test_release_version():
    import transcribe

    assert transcribe.__version__ == "0.3.0"
