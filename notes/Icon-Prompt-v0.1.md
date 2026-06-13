# OnlyFollow App Icon 生成 Prompt

> 用途：豆包 / 其他生图工具直接复制使用
> 风格：方案 A「F + 心形」

---

## 提醒事项

- ⚠️ iOS 图标不能透明背景（必须纯色）
- ⚠️ 不要自己加圆角矩形框（iOS 系统会自动加圆角蒙版）
- ⚠️ F 字母不能太细，缩小到 60×60 会糊
- ⚠️ 心形不能太大，否则会抢 F 的视觉重量
- 💡 一次生成 4 张，挑最戳的那张
- 💡 导出后确认是 1024×1024

---

## 🇨🇳 中文完整版（首选）

```
iOS App 图标设计，正方形 1024x1024，扁平矢量风格，极简现代。

【主体内容】
- 画面中央偏左：一个粗体圆角无衬线的大写字母 "F"，字母高度约占图标 80%，笔画粗壮清晰
- 字母右上角外侧：一颗小号实心心形，距离字母约半笔画的距离，大小约为字母的 1/5
- 心形微微倾斜 15° 左右，增加灵动感

【配色】
- 背景：奶油白 #FAF5EC（纯色填充）
- 字母 F：樱花粉 #F5A5B5
- 心形：玫瑰粉 #E88599（比字母深一档）

【风格要求】
- 扁平设计（flat design），无 3D 效果
- 无阴影、无投影、无立体感
- 极简，背景纯净无装饰
- 字母和心形视觉重量平衡，整体居中

【技术要求】
- 必须纯色背景，不允许透明
- 字母和心形边缘锐利清晰
- 不要圆角矩形外框（系统会自动加圆角蒙版）
- 设计在缩小到 60x60 像素时仍清晰可辨

【负面提示】
3D, shadow, gradient, photo, realistic, complex background, rounded square frame, transparency, watermark, text other than the letter F
```

---

## 🇬🇧 英文完整版（备选）

```
iOS App icon, 1024x1024 square, flat vector style, minimalist, modern.

[Main content]
- Center-left: a bold rounded sans-serif uppercase letter "F", height about 80% of icon, thick and clear strokes
- Upper-right outside the letter: a small solid heart shape, tilted about 15 degrees, size about 1/5 of the letter, with half-stroke distance from the letter

[Colors]
- Background: cream white #FAF5EC (solid)
- Letter F: cherry blossom pink #F5A5B5
- Heart: rose pink #E88599 (one shade darker)

[Style]
- Flat design, no 3D effect
- No shadow, no projection, no depth
- Minimalist, clean solid background
- Letter and heart visually balanced, centered as a whole

[Technical]
- Must be solid color background, no transparency
- Sharp clear edges on letter and heart
- Do NOT add rounded square frame (iOS adds it automatically)
- Must remain clear and recognizable when scaled to 60x60 pixels

[Negative]
3D, shadow, gradient, photo, realistic, complex background, rounded square frame, transparency, watermark, extra text
```

---

## 🪶 极简版（备用）

```
iOS App 图标 1024x1024，扁平矢量极简风格。中央一个粗体圆角大写字母 "F"（樱花粉 #F5A5B5），右上角一颗小爱心（玫瑰粉 #E88599），奶油白 #FAF5EC 纯色背景，无 3D 无阴影无圆角框，缩小到 60x60 仍清晰。
```

---

## 生图后检查清单

- [ ] 尺寸是 1024×1024
- [ ] 背景是纯色（无透明）
- [ ] F 字母清晰可辨
- [ ] 心形是装饰大小，不抢 F 的视觉
- [ ] 没有圆角矩形外框
- [ ] 没有水印/其他文字
- [ ] 缩小到 60×60 模拟图仍清晰
