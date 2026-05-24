# Bubble Zoom KOReader Plugin

This plugin enables users to magnify a speech bubble on a comics/manga page by tapping or long pressing it. You can access the plugin's settings from the Typesetting menu (second from the left) in the top menu bar.

<img src="img/bubblezoom_demo_low_v1_1.gif" width="450">

*Plugin preview*

https://github.com/user-attachments/assets/e5a885fc-9271-42f8-bff2-121fc6dd94eb

*Offline translation preview*

# Installation

Download the latest version of the plugin from the [releases](https://github.com/anezih/bubblezoom.koplugin/releases). Copy the `bubblezoom.koplugin` folder to your KOReader installation's `plugins` directory.

# Offline Translator Integration

Bubble Zoom can use `offlinetranslator.koplugin` to OCR enlarged speech bubbles
and translate them locally. The Bubble Zoom settings menu includes automatic
bubble translation, translation on long-press of an enlarged bubble, translation
direction, OCR engine, and OCR engine-specific options.

For comics, PPOCR is usually the most useful OCR engine for speech bubbles and
mixed page text when its PP-OCRv5 files are installed. For Japanese manga,
Manga OCR is often the best option for vertical and multi-line bubbles.
Tesseract remains a small fallback and works well for some languages, but for
Japanese vertical text it can produce sub-optimal results.

The Offline Translator integration is supported only on Linux x86_64 and
Android arm64-v8a builds. Install Offline Translator and its data files from:
https://github.com/anezih/offlinetranslator.koplugin


# Disclosure

I've written and streamlined the image processing workflow (luma calculations, integral images, sauvola thresholding, flood fill and morphological closing) in C# as a PoC. However, I've used ChatGPT codex to create the final lua plugin, as KOReader documentation's drawing and input interception parts are not easy to get into.

# References
- J. Sauvola and M. Pietikainen, “Adaptive document image binarization,” Pattern Recognition 33(2), pp. 225-236, 2000. DOI:10.1016/S0031-3203(99)00055-2

- Comic shown in the preview video: https://www.teamfortress.com/tf05_old_wounds/
