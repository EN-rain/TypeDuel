# Character Button TextureRect Guide

## Problem
When adding TextureRect as a child to character buttons, the texture doesn't appear or seems hidden.

## Root Cause
Buttons in Godot have `clip_contents = true` by default, which hides any child nodes that extend beyond the button's boundaries. Additionally, buttons have internal rendering that can overlap children.

## Solution

### Option 1: Use Button Icon (Recommended)
Instead of adding a TextureRect child, use the button's built-in icon property:

1. In the scene editor, select a character button (e.g., `Character1`)
2. In the Inspector, find the **Icon** property under the Button section
3. Drag your texture resource into the Icon field
4. Adjust **Icon Alignment** (Left, Center, Right)
5. Set **Expand Icon** to true if you want it to scale

**In the .tscn file:**
```gdscript
[node name="Character1" type="Button"]
custom_minimum_size = Vector2(150, 80)
layout_mode = 2
text = "Character 1"
icon = ExtResource("path_to_your_texture")
expand_icon = true
icon_alignment = 1  # 0=Left, 1=Center, 2=Right
```

### Option 2: TextureRect as Child (Advanced)
If you need more control, add TextureRect as a child:

1. Select the character button
2. In Inspector, set **Clip Contents** to `false`
3. Add TextureRect as a child node
4. Set TextureRect properties:
   - **Mouse Filter**: Ignore (so clicks pass through to button)
   - **Layout Mode**: Anchors
   - **Anchors Preset**: Full Rect or Center
   - **Expand Mode**: Ignore Size or Keep Aspect Centered
   - **Stretch Mode**: Scale or Keep Aspect Centered

**In the .tscn file:**
```gdscript
[node name="Character1" type="Button"]
custom_minimum_size = Vector2(150, 80)
layout_mode = 2
text = "Character 1"
clip_contents = false  # IMPORTANT!

[node name="Portrait" type="TextureRect" parent="Characters/VBoxContainer/Character1"]
layout_mode = 1
anchors_preset = 15  # Full Rect
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
texture = ExtResource("path_to_your_texture")
expand_mode = 1  # Keep Aspect Centered
stretch_mode = 5  # Keep Aspect Centered
mouse_filter = 2  # Ignore - allows clicks to pass through
```

### Option 3: TextureButton (Alternative)
Use TextureButton instead of regular Button:

```gdscript
[node name="Character1" type="TextureButton"]
custom_minimum_size = Vector2(150, 80)
layout_mode = 2
texture_normal = ExtResource("path_to_normal_texture")
texture_pressed = ExtResource("path_to_pressed_texture")
texture_hover = ExtResource("path_to_hover_texture")
ignore_texture_size = true
stretch_mode = 5  # Keep Aspect Centered
```

Then add a Label child for the text.

## Current Scene Structure

The scene is now set up with:
- ✅ All button signals properly connected in the .tscn file
- ✅ Character buttons: `Characters/VBoxContainer/Character1-3`
- ✅ Skill buttons: `Skill/VBoxContainer/Skill1-3`
- ✅ Passive buttons: `Passive/HBoxContainer/VBoxContainer1-3/Passive1-5`
- ✅ `clip_contents = false` enabled on character buttons

## Adding Character Portraits

### Step-by-step in Godot Editor:

1. **Open the scene**: `game/scenes/ui/custom_room.tscn`

2. **For each character button**:
   - Expand `Characters` → `VBoxContainer` → `Character1`
   - Right-click `Character1` → Add Child Node → TextureRect
   - Name it `Portrait`

3. **Configure the TextureRect**:
   - Select `Portrait`
   - In Inspector:
     - **Texture**: Drag your character portrait image
     - **Layout** → **Anchors Preset**: Full Rect
     - **Expand Mode**: Keep Aspect Centered
     - **Stretch Mode**: Keep Aspect Centered
     - **Mouse Filter**: Ignore

4. **Adjust button text** (optional):
   - Select `Character1` button
   - In Inspector → **Text** → Clear or adjust
   - Or add a Label child for better text positioning

5. **Repeat for Character2 and Character3**

## Troubleshooting

### Texture still not visible?
- Check that `clip_contents = false` on the button
- Verify texture path is correct in Inspector
- Check TextureRect is actually a child of the button in Scene tree
- Ensure TextureRect has proper anchors/size
- Try setting TextureRect **Modulate** to white (1, 1, 1, 1)

### Texture visible but can't click button?
- Set TextureRect **Mouse Filter** to "Ignore"

### Texture wrong size?
- Use **Expand Mode**: Keep Aspect Centered
- Use **Stretch Mode**: Keep Aspect Centered
- Or adjust **Custom Minimum Size** on the button

### Want texture behind text?
- Move TextureRect to be the first child of the button
- Or use button's **Icon** property instead
