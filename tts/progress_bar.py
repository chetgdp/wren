import torch
from tqdm.auto import tqdm
from transformers import StoppingCriteria, StoppingCriteriaList


def estimate_frames(text: str) -> int:
    """Rough prediction of how many 12 Hz audio frames `text` will generate.

    English speech runs ~12-14 chars/sec and the codec emits 12 frames/sec, so
    frames ~= chars * 0.9. Approximate — actual length varies with content,
    punctuation, and pacing.
    """
    return round(len(text.strip()) * 0.9)


def attach_progress_bar(tts_model):
    """Tick a tqdm bar once per generated audio frame.

    qwen_tts doesn't forward a streamer/stopping_criteria through
    generate_voice_clone, but the underlying talker is a transformers
    GenerationMixin, so we inject a no-op StoppingCriteria (always returns
    False) that updates a bar each decode step. Best-effort: if the internal
    layout changes, generation still runs without a bar.
    """
    try:
        talker = tts_model.model.talker
    except AttributeError:
        return

    orig_generate = talker.generate

    class _BarTick(StoppingCriteria):
        def __init__(self):
            # total=None -> indeterminate: shows frame count, elapsed, rate.
            # There's no meaningful endpoint (generation stops at a
            # dynamic EOS), so we just track progress as it happens.
            self.bar = tqdm(total=None, unit="frame", desc="synthesizing")

        def __call__(self, input_ids, scores, **kwargs):
            self.bar.update(1)
            return torch.zeros(input_ids.shape[0], dtype=torch.bool,
                               device=input_ids.device)

    def patched(*args, **kw):
        tick = _BarTick()
        criteria = kw.get("stopping_criteria") or StoppingCriteriaList()
        criteria.append(tick)
        kw["stopping_criteria"] = criteria
        try:
            return orig_generate(*args, **kw)
        finally:
            tick.bar.close()

    talker.generate = patched
