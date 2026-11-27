#!/usr/bin/env python3
"""Cuts the generated animal sheets (4x2 on a dark ground) into single
transparent sprites and writes them into the app's asset catalog.

Usage: slice.py <folder with style-*.png> <Assets.xcassets>
"""
import json
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

ANIMALS = ["fox", "whale", "snail", "hedgehog", "owl", "octopus", "bat", "frog"]
STYLES = {"pixel": "style-a-pixel.png", "soft": "style-b-soft.png", "sticker": "style-c-sticker.png"}
SIZE = 256


def cut_out(sheet):
    """Makes the dark ground transparent by flooding in from the border."""
    image = sheet.convert("RGBA")
    width, height = image.size
    seeds = [(x, y) for x in range(0, width, 8) for y in (0, height - 1)]
    seeds += [(x, y) for y in range(0, height, 8) for x in (0, width - 1)]
    for seed in seeds:
        if image.getpixel(seed)[3] != 0:
            ImageDraw.floodfill(image, seed, (0, 0, 0, 0), thresh=60)
    return image


def blobs(alpha, scale=4):
    """Connected shapes of the cut-out sheet, found on a reduced copy.
    Returns the label image (reduced size) and each label's centre and area."""
    small = alpha.resize((alpha.width // scale, alpha.height // scale), Image.BILINEAR).point(lambda v: 255 if v > 40 else 0)
    width, height = small.size
    pixels = small.load()
    labels = [[0] * width for _ in range(height)]
    found = {}
    current = 0
    for y in range(height):
        for x in range(width):
            if not pixels[x, y] or labels[y][x]:
                continue
            current += 1
            stack = [(x, y)]
            labels[y][x] = current
            sx = sy = count = 0
            while stack:
                cx, cy = stack.pop()
                sx += cx
                sy += cy
                count += 1
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < width and 0 <= ny < height and pixels[nx, ny] and not labels[ny][nx]:
                        labels[ny][nx] = current
                        stack.append((nx, ny))
            found[current] = (sx / count * scale, sy / count * scale, count)
    return labels, found


def main(source, catalog):
    os.makedirs(catalog, exist_ok=True)
    with open(os.path.join(catalog, "Contents.json"), "w") as file:
        json.dump({"info": {"author": "xcode", "version": 1}}, file, indent=2)
    for style, name in STYLES.items():
        sheet = cut_out(Image.open(os.path.join(source, name)))
        width, height = sheet.size
        alpha = sheet.getchannel("A")
        if style != "pixel":
            # Take one pixel off the edge, where the dark ground still shows through.
            alpha = alpha.filter(ImageFilter.MinFilter(3))
        labels, found = blobs(alpha)
        for index, animal in enumerate(ANIMALS):
            column, row = index % 4, index // 4
            # A figure is every shape whose centre lies in its cell: a neighbour
            # reaching over the line stays with the neighbour.
            mine = {label for label, (x, y, count) in found.items()
                    if count > 12 and int(x * 4 // width) == column and int(y * 2 // height) == row}
            mask = Image.new("L", (len(labels[0]), len(labels)), 0)
            mask.putdata([255 if value in mine else 0 for line in labels for value in line])
            mask = mask.filter(ImageFilter.MaxFilter(5)).resize((width, height), Image.NEAREST)
            figure = sheet.copy()
            figure.putalpha(Image.composite(alpha, Image.new("L", (width, height), 0), mask))
            box = figure.getchannel("A").getbbox()
            figure = figure.crop(box)
            side = max(figure.size)
            square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
            square.paste(figure, ((side - figure.width) // 2, (side - figure.height) // 2))
            square = square.resize((SIZE, SIZE), Image.NEAREST if style == "pixel" else Image.LANCZOS)
            folder = os.path.join(catalog, f"figure-{style}-{animal}.imageset")
            os.makedirs(folder, exist_ok=True)
            square.save(os.path.join(folder, "figure.png"))
            with open(os.path.join(folder, "Contents.json"), "w") as file:
                json.dump({"images": [{"idiom": "universal", "filename": "figure.png"}],
                           "info": {"author": "xcode", "version": 1}}, file, indent=2)
            print(style, animal, figure.size, len(mine), "shapes")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
