"""Builds Sources/AIWallpaper/Resources/Segmentation.mlpackage.

Only needed when the model changes. Wants a Python the current coremltools
supports, which is not the newest one:

    python3.12 -m venv ml && ./ml/bin/pip install torch transformers coremltools
    ./ml/bin/python tools/convert-model.py

The wrapper folds the ImageNet normalisation and the argmax into the graph, so
the app hands Core ML an image and gets one class index per pixel back.
"""

import torch, coremltools as ct
from transformers import UperNetForSemanticSegmentation

SIDE = 512
m = UperNetForSemanticSegmentation.from_pretrained("openmmlab/upernet-convnext-tiny").eval()

class Wrap(torch.nn.Module):
    def __init__(s, m):
        super().__init__(); s.m = m
        # ImageNet normalisation, folded in so Core ML can take a plain image.
        s.register_buffer("mean", torch.tensor([0.485,0.456,0.406]).view(1,3,1,1))
        s.register_buffer("std",  torch.tensor([0.229,0.224,0.225]).view(1,3,1,1))
    def forward(s, x):
        x = (x - s.mean) / s.std
        return s.m(pixel_values=x).logits.argmax(1).to(torch.int32)

w = Wrap(m).eval()
ex = torch.rand(1,3,SIDE,SIDE)
with torch.no_grad():
    out = w(ex)
print("traced out", out.shape, out.dtype)
ts = torch.jit.trace(w, ex)
mlm = ct.convert(ts,
    inputs=[ct.ImageType(name="image", shape=(1,3,SIDE,SIDE), scale=1/255.0)],
    outputs=[ct.TensorType(name="semanticPredictions")],
    convert_to="mlprogram", minimum_deployment_target=ct.target.macOS13)
mlm = ct.optimize.coreml.linear_quantize_weights(mlm,
    ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")))
mlm.save("Sources/AIWallpaper/Resources/Segmentation.mlpackage")
print("saved")
