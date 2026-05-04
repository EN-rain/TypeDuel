import time

import pyautogui


def is_blue(rgb: tuple[int, int, int]) -> bool:
    r, g, b = rgb
    min_b = 170
    min_delta = 60
    return b >= min_b and (b - r) >= min_delta and (b - g) >= min_delta


def main() -> None:
    pyautogui.FAILSAFE = True
    sample_interval_s = 0.02
    click_cooldown_s = 0.35
    last_click = 0.0

    print("Running. Hover a blue pixel to auto-click. Stop with Ctrl+C (or move mouse to top-left corner).")

    while True:
        x, y = pyautogui.position()
        rgb = pyautogui.pixel(x, y)

        now = time.time()
        if is_blue(rgb) and (now - last_click) >= click_cooldown_s:
            pyautogui.click(x, y)
            last_click = now

        time.sleep(sample_interval_s)


if __name__ == "__main__":
    main()
