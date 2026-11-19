"""session_review: review coding-agent sessions as good/bad/outlier examples.

Layers: adapters/<harness>.py turn raw logs into the normalized model (model.py);
metrics.py scores it; render.py and overview.py produce HTML. Only adapters know a harness's log format.
"""
