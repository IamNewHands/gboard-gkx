#!/usr/bin/env python3
"""Numerical geometry replay, NOT UIKit execution; source wiring is in test_perf."""
import math
import unittest


def hit_band(row, glyph, carrier_right, right=None):
    x, y, w, h = row
    gx, gy, gw, gh = glyph
    values = (*row, *glyph, carrier_right) + (() if right is None else (right,))
    if not all(math.isfinite(value) for value in values) or min(w, h, gw, gh) <= 0:
        return None
    height = max(28.0, gh)
    # A header row shorter than the ideal band shrinks the hit area to the row, never the glyph.
    if height > h:
        height = h
    if height < 18.0:
        return None
    left = max(gx + gw + 4.0, carrier_right)
    top = max(y, min(gy + gh / 2.0 - height / 2.0, y + h - height))
    right = x + w if right is None else right
    if (not all(math.isfinite(value) for value in (left, top, right, height, right - left))
            or right - left < 200.0
            or left < x or right > x + w or top < y or top + height > y + h):
        return None
    return left, top, right - left, height


def title_fits(band, center, height, width=32.0):
    return (band is not None and center - height / 2 >= band[1]
            and center + height / 2 <= band[1] + band[3]
            and width <= band[2] / 5)


class ToolbarGeometryReplay(unittest.TestCase):
    def test_log4_keeps_upper_and_selected_native_hits_clear(self):
        # Root coordinates: old (43,22,359,28) intersects upper native hit (0,0,402,26).
        band = hit_band((0, 26, 402, 44), (17, 26, 22, 20), 56)
        self.assertEqual((56, 26, 346, 28), band)
        self.assertGreaterEqual(band[1], 26)
        self.assertGreaterEqual(band[0], 56)
        self.assertTrue(title_fits(band, 36, 19.2))
        self.assertEqual(36, band[1] + (36 - band[1]))
        self.assertNotEqual(36, band[1] + band[3] / 2)

    def test_top_bottom_and_nonzero_bounds(self):
        for glyph, top in (((27, 20, 22, 20), 20), ((27, 44, 22, 20), 36)):
            with self.subTest(glyph=glyph):
                band = hit_band((10, 20, 402, 44), glyph, 66)
                self.assertEqual(top, band[1])
                self.assertTrue(title_fits(band, glyph[1] + 10, 19.2))

    def test_candidate_outside_row_is_rejected_with_valid_nonzero_counterpart(self):
        self.assertIsNone(hit_band((100, 26, 402, 44), (17, 26, 22, 20), 56))
        self.assertIsNone(hit_band((100, 26, 402, 44), (117, 26, 22, 20), 156, right=503))
        self.assertEqual((156, 26, 346, 28),
                         hit_band((100, 26, 402, 44), (117, 26, 22, 20), 156))

    def test_nonfinite_and_empty_measurements_are_rejected(self):
        row, glyph = (0, 26, 402, 44), (17, 26, 22, 20)
        for value in (float('nan'), float('inf'), float('-inf')):
            for index in range(4):
                invalid_row, invalid_glyph = list(row), list(glyph)
                invalid_row[index] = invalid_glyph[index] = value
                with self.subTest(value=value, index=index):
                    self.assertIsNone(hit_band(invalid_row, glyph, 56))
                    self.assertIsNone(hit_band(row, invalid_glyph, 56))
            self.assertIsNone(hit_band(row, glyph, value))
            self.assertIsNone(hit_band(row, glyph, 56, right=value))
        self.assertIsNone(hit_band((0, 26, 0, 44), glyph, 56))
        self.assertIsNone(hit_band(row, (17, 26, 0, 20), 56))

    def test_short_row_shrinks_the_band_instead_of_dropping_the_toolbar(self):
        # 22 pt header row: the band is clipped to the row, so the 20 pt G stays inside it.
        self.assertEqual((56, 0, 346, 22), hit_band((0, 0, 402, 22), (17, 0, 22, 20), 56))
        self.assertTrue(title_fits(hit_band((0, 0, 402, 22), (17, 0, 22, 20), 56), 10, 19.2))
        # Below 18 pt no title fits, so the row is still refused.
        self.assertIsNone(hit_band((0, 0, 402, 16), (17, 0, 22, 14), 56))

    def test_other_native_obstacles_still_limit_width(self):
        self.assertIsNone(hit_band((0, 26, 402, 44), (17, 26, 22, 20), 56, right=200))
        self.assertIsNone(hit_band((0, 26, 402, 44), (17, 26, 22, 20), 250))

    def test_actual_text_height_and_width_cannot_be_clipped_or_scaled(self):
        band = hit_band((0, 26, 402, 44), (17, 26, 22, 20), 56)
        self.assertFalse(title_fits(band, 36, 21))
        self.assertFalse(title_fits(band, 36, 19.2, width=70))
        self.assertTrue(title_fits(band, 36, 20))

    def test_same_hit_band_does_not_authorize_stale_g_center(self):
        row = (0, 26, 402, 44)
        first = hit_band(row, (17, 26, 22, 20), 56)
        second = hit_band(row, (17, 27, 22, 20), 56)
        self.assertEqual(first, second)
        self.assertTrue(title_fits(first, 36, 19.2))
        self.assertTrue(title_fits(second, 37, 19.2))
        self.assertNotEqual(36 - first[1], 37 - second[1])


if __name__ == "__main__":
    unittest.main()
