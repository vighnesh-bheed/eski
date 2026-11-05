package main

import "core:math"

Lolwut_Canvas :: struct {
	width, height: int,
	pixels: []u8,
}

lolwut_canvas :: proc(width, height: int, background: u8) -> Lolwut_Canvas {
	canvas := Lolwut_Canvas{width, height, make([]u8, width * height)}
	for &pixel in canvas.pixels {
		pixel = background
	}
	return canvas
}

lolwut_pixel :: proc(canvas: Lolwut_Canvas, x, y: int, color: u8) {
	if x >= 0 && x < canvas.width && y >= 0 && y < canvas.height {
		canvas.pixels[x + y * canvas.width] = color
	}
}

lolwut_get :: proc(canvas: Lolwut_Canvas, x, y: int) -> u8 {
	if x < 0 || x >= canvas.width || y < 0 || y >= canvas.height {
		return 0
	}
	return canvas.pixels[x + y * canvas.width]
}

lolwut_line :: proc(canvas: Lolwut_Canvas, x1, y1, x2, y2: int) {
	x, y := x1, y1
	dx, dy := abs(x2 - x1), abs(y2 - y1)
	sx := 1 if x1 < x2 else -1
	sy := 1 if y1 < y2 else -1
	err := dx - dy
	for {
		lolwut_pixel(canvas, x, y, 1)
		if x == x2 && y == y2 {
			break
		}
		e2 := err * 2
		if e2 > -dy {
			err -= dy
			x += sx
		}
		if e2 < dx {
			err += dx
			y += sy
		}
	}
}

lolwut_square :: proc(canvas: Lolwut_Canvas, x, y: int, size, angle: f32) {
	radius := math.round(size / f32(1.4142135623))
	k := f32(math.PI / 4) + angle
	px, py: [4]int
	for j in 0 ..< 4 {
		px[j] = int(math.round(math.sin(f64(k)) * f64(radius) + f64(x)))
		py[j] = int(math.round(math.cos(f64(k)) * f64(radius) + f64(y)))
		k += f32(math.PI / 2)
	}
	for j in 0 ..< 4 {
		lolwut_line(canvas, px[j], py[j], px[(j + 1) % 4], py[(j + 1) % 4])
	}
}

lolwut_random :: proc() -> f32 {
	return f32(rng_next() >> 40) / f32(0xffffff)
}

lolwut_schotter :: proc(columns, squares_x, squares_y: int) -> Lolwut_Canvas {
	width := columns * 2
	padding := 2 if width > 4 else 0
	side := f32(width - padding * 2) / f32(squares_x)
	canvas := lolwut_canvas(width, int(side * f32(squares_y) + f32(padding * 2)), 0)
	for y in 0 ..< squares_y {
		for x in 0 ..< squares_x {
			sx := int(f32(x) * side + side / 2 + f32(padding))
			sy := int(f32(y) * side + side / 2 + f32(padding))
			angle: f32
			if y > 1 {
				r1 := lolwut_random() / f32(squares_y) * f32(y)
				r2 := lolwut_random() / f32(squares_y) * f32(y)
				r3 := lolwut_random() / f32(squares_y) * f32(y)
				if rng_next() % 2 != 0 { r1 = -r1 }
				if rng_next() % 2 != 0 { r2 = -r2 }
				if rng_next() % 2 != 0 { r3 = -r3 }
				angle = r1
				sx = int(f32(sx) + r2 * side / 3)
				sy = int(f32(sy) + r3 * side / 3)
			}
			lolwut_square(canvas, sx, sy, side, angle)
		}
	}
	return canvas
}

lolwut_braille :: proc(canvas: Lolwut_Canvas, output: ^[dynamic]u8) {
	xoff := [8]int{0, 0, 0, 1, 1, 1, 0, 1}
	yoff := [8]int{0, 1, 2, 0, 1, 2, 3, 3}
	for y := 0; y < canvas.height; y += 4 {
		for x := 0; x < canvas.width; x += 2 {
			code: u32 = 0x2800
			for bit in 0 ..< 8 {
				if lolwut_get(canvas, x + xoff[bit], y + yoff[bit]) != 0 {
					code |= u32(1) << uint(bit)
				}
			}
			append(output, u8(0xe0 | (code >> 12)), u8(0x80 | ((code >> 6) & 63)), u8(0x80 | (code & 63)))
		}
		if y != canvas.height - 1 {
			append(output, '\n')
		}
	}
}

lolwut_building :: proc(canvas: Lolwut_Canvas, offset, width, height: int, windows: bool, shade: u8) {
	start := canvas.height - 1
	end := start - height + 1
	for y := start; y >= end; y -= 1 {
		for x in offset ..< offset + width {
			if y == end && (x <= offset + 1 || x >= offset + width - 2) {
				continue
			}
			color := shade
			if windows && x > offset + 1 && x < offset + width - 2 && y > end + 1 && y < start - 1 {
				rx, ry := x - (offset + 1), y - (end + 1)
				if rx / 2 % 2 != 0 && ry % 2 != 0 {
					for {
						color = 1 + u8(rng_next() % 2)
						if color != shade { break }
					}
					if rx % 2 != 0 { color = lolwut_get(canvas, x - 1, y) }
				}
			}
			lolwut_pixel(canvas, x, y, color)
		}
	}
}

lolwut_skyline :: proc(canvas: Lolwut_Canvas) {
	for color := 2; color >= 1; color -= 1 {
		for offset := -10; offset < canvas.width; {
			offset += int(rng_next() % 8)
			width := 10 + int(rng_next() % 9)
			height := canvas.height / 2 + int(rng_next() % u64(canvas.height)) / (2 if color == 2 else 3)
			lolwut_building(canvas, offset, width, height, false, u8(color))
			offset += width / 2 if color == 2 else width + 1
		}
	}
	for offset := -10; offset < canvas.width; {
		offset += int(rng_next() % 8)
		width := 5 + int(rng_next() % 14)
		if width % 4 != 0 { width += width % 3 }
		height := canvas.height / 3 + int(rng_next() % u64(canvas.height)) / 2
		lolwut_building(canvas, offset, width, height, true, 0)
		offset += width + 5
	}
}

lolwut_gray :: proc(canvas: Lolwut_Canvas, output: ^[dynamic]u8) {
	colors := [4]string{"0;30;40m", "0;90;100m", "0;37;47m", "0;97;107m"}
	for y in 0 ..< canvas.height {
		for x in 0 ..< canvas.width {
			sb_str(output, "\x1b[")
			sb_str(output, colors[lolwut_get(canvas, x, y)])
			sb_str(output, " \x1b[0m")
		}
		if y != canvas.height - 1 { sb_byte(output, '\n') }
	}
}

cmd_lolwut :: proc(c: ^Conn, argv: [][]u8) {
	version: i64 = 7
	args := argv[1:]
	if len(argv) >= 3 && eq_nocase(argv[1], "version") {
		var_ok: bool
		version, var_ok = parse_i64(argv[2])
		if !var_ok { reply_error(c, ERR_NOT_INT); return }
		args = argv[3:]
	}
	output: [dynamic]u8
	defer delete(output)
	if u32(version) == 5 || u32(version) == 6 {
		values := [3]i64{66, 8, 12}
		count := 3
		if u32(version) == 6 { values = {80, 20, 0}; count = 2 }
		for i in 0 ..< min(len(args), count) {
			value, ok := parse_i64(args[i])
			if !ok { reply_error(c, ERR_NOT_INT); return }
			values[i] = value
		}
		columns := int(clamp(values[0], 1, 1000))
		if u32(version) == 5 {
			canvas := lolwut_schotter(columns, int(clamp(values[1], 1, 200)), int(clamp(values[2], 1, 200)))
			defer delete(canvas.pixels)
			lolwut_braille(canvas, &output)
			sb_str(&output, "\nGeorg Nees - schotter, plotter on paper, 1968. ")
		} else {
			canvas := lolwut_canvas(columns, int(clamp(values[1], 1, 1000)), 3)
			defer delete(canvas.pixels)
			lolwut_skyline(canvas)
			lolwut_gray(canvas, &output)
			sb_str(&output, "\nDedicated to the 8 bit game developers of past and present.\nOriginal 8 bit image from Plaguemon by hikikomori. ")
		}
	}
	sb_str(&output, "Redis ver. ")
	sb_str(&output, REDIS_COMPAT_VERSION)
	sb_byte(&output, '\n')
	reply_verbatim(c, output[:])
}

lolwut_commands := [?]Command{{"lolwut", cmd_lolwut, -1}}

@(init)
register_lolwut_commands :: proc "contextless" () {
	register_commands(lolwut_commands[:])
}
