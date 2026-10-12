#!/usr/bin/env python3
"""Convert Real-ESRGAN PyTorch weights to Core ML (.mlpackage) for the iOS app.

The network definitions below are copied from BasicSR / Real-ESRGAN so the script does not
depend on the (unmaintained) ``basicsr`` package. Each exported model takes a fixed-size RGB
tile (``--tile`` x ``--tile``) and returns the super-resolved RGB tile as an image, so the app
can feed CVPixelBuffers directly and stitch tiles together.

Usage:
    python tools/convert_models.py --weights weights --out build/models
"""

import argparse
import json
import os
import urllib.request

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

# --------------------------------------------------------------------------------------------
# Architectures (from basicsr.archs.rrdbnet_arch and realesrgan.archs.srvgg_arch)
# --------------------------------------------------------------------------------------------


class ResidualDenseBlock(nn.Module):

    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):

    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):

    def __init__(self, num_in_ch, num_out_ch, scale=4, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch = num_in_ch * 4
        elif scale == 1:
            num_in_ch = num_in_ch * 16
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        if self.scale == 2:
            feat = F.pixel_unshuffle(x, 2)
        elif self.scale == 1:
            feat = F.pixel_unshuffle(x, 4)
        else:
            feat = x
        feat = self.conv_first(feat)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode='nearest')))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode='nearest')))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


class SRVGGNetCompact(nn.Module):

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode='nearest')
        return out + base


class ImageOutputWrapper(nn.Module):
    """Maps the network's [0, 1] RGB output to [0, 255] so Core ML can emit an image."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        y = self.net(x)
        return torch.clamp(y, 0.0, 1.0) * 255.0


# --------------------------------------------------------------------------------------------
# Model catalogue (mirrors inference_realesrgan.py / app.py)
# --------------------------------------------------------------------------------------------

RELEASE = 'https://github.com/xinntao/Real-ESRGAN/releases/download'
WEIGHT_URLS = {
    'RealESRGAN_x4plus': f'{RELEASE}/v0.1.0/RealESRGAN_x4plus.pth',
    'RealESRGAN_x4plus_anime_6B': f'{RELEASE}/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth',
    'RealESRGAN_x2plus': f'{RELEASE}/v0.2.1/RealESRGAN_x2plus.pth',
    'realesr-general-x4v3': f'{RELEASE}/v0.2.5.0/realesr-general-x4v3.pth',
    'realesr-general-wdn-x4v3': f'{RELEASE}/v0.2.5.0/realesr-general-wdn-x4v3.pth',
}

# Denoise strengths baked for realesr-general-x4v3 (DNI between x4v3 and wdn-x4v3).
DENOISE_LEVELS = [0.0, 0.25, 0.5, 0.75, 1.0]


def build_specs():
    specs = [
        dict(id='RealESRGAN_x4plus', scale=4, weights=['RealESRGAN_x4plus'],
             net=lambda: RRDBNet(3, 3, scale=4, num_feat=64, num_block=23, num_grow_ch=32)),
        dict(id='RealESRGAN_x4plus_anime_6B', scale=4, weights=['RealESRGAN_x4plus_anime_6B'],
             net=lambda: RRDBNet(3, 3, scale=4, num_feat=64, num_block=6, num_grow_ch=32)),
        dict(id='RealESRGAN_x2plus', scale=2, weights=['RealESRGAN_x2plus'],
             net=lambda: RRDBNet(3, 3, scale=2, num_feat=64, num_block=23, num_grow_ch=32)),
    ]
    for level in DENOISE_LEVELS:
        specs.append(
            dict(id=f'realesr-general-x4v3_dn{int(round(level * 100)):03d}', scale=4,
                 weights=['realesr-general-x4v3', 'realesr-general-wdn-x4v3'], dni=[level, 1 - level],
                 net=lambda: SRVGGNetCompact(3, 3, num_feat=64, num_conv=32, upscale=4)))
    return specs


def fetch(name, weights_dir):
    path = os.path.join(weights_dir, f'{name}.pth')
    if not os.path.isfile(path):
        os.makedirs(weights_dir, exist_ok=True)
        print(f'Downloading {WEIGHT_URLS[name]}')
        urllib.request.urlretrieve(WEIGHT_URLS[name], path)
    return path


def load_params(path):
    state = torch.load(path, map_location='cpu', weights_only=True)
    # Real-ESRGAN prefers the EMA weights when present.
    return state['params_ema'] if 'params_ema' in state else state['params']


def build_network(spec, weights_dir):
    net = spec['net']()
    paths = [fetch(w, weights_dir) for w in spec['weights']]
    if 'dni' in spec:
        a, b = (load_params(p) for p in paths)
        wa, wb = spec['dni']
        params = {k: wa * v + wb * b[k] for k, v in a.items()}
    else:
        params = load_params(paths[0])
    net.load_state_dict(params, strict=True)
    return net.eval()


def convert(spec, weights_dir, out_dir, tile):
    net = build_network(spec, weights_dir)
    model = ImageOutputWrapper(net).eval()
    example = torch.rand(1, 3, tile, tile)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
        reference = model(example).numpy()

    mlmodel = ct.convert(
        traced,
        convert_to='mlprogram',
        inputs=[ct.ImageType(name='input', shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name='output', color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.short_description = f"Real-ESRGAN {spec['id']} (x{spec['scale']}, tile {tile})"
    mlmodel.author = 'Xintao Wang et al. (Real-ESRGAN), converted for iOS'
    mlmodel.license = 'BSD-3-Clause'
    mlmodel.user_defined_metadata['scale'] = str(spec['scale'])
    mlmodel.user_defined_metadata['tile'] = str(tile)

    path = os.path.join(out_dir, f"{spec['id']}.mlpackage")
    mlmodel.save(path)
    print(f"Saved {path}  (torch output range {reference.min():.1f}..{reference.max():.1f})")
    return dict(id=spec['id'], scale=spec['scale'], tile=tile)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--weights', default='weights', help='Folder holding / receiving the .pth files')
    parser.add_argument('--out', default='build/models', help='Output folder for .mlpackage files')
    parser.add_argument('--tile', type=int, default=256, help='Fixed input tile size of the Core ML models')
    parser.add_argument('--only', nargs='*', help='Convert only these model ids')
    args = parser.parse_args()

    torch.manual_seed(0)
    np.random.seed(0)
    os.makedirs(args.out, exist_ok=True)
    manifest = []
    for spec in build_specs():
        if args.only and spec['id'] not in args.only:
            continue
        manifest.append(convert(spec, args.weights, args.out, args.tile))
    with open(os.path.join(args.out, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, indent=2)


if __name__ == '__main__':
    main()
