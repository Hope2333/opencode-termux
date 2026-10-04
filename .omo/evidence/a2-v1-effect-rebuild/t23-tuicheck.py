import sys, re
d = open(sys.argv[1], "rb").read()
print("total bytes:", len(d))
print("ESC[?1049h (altscreen):", d.count(b"\x1b[?1049h"))
print("ESC[?1000h (mouse):     ", d.count(b"\x1b[?1000h"))
print("OSC10/11 (fg/bg):       ", len(re.findall(rb"\x1b\]1[01];", d)))
print("Gi=31337 (graphics):    ", len(re.findall(rb"\x1b_Gi?=?31337", d)))
marks = [b"Segmentation", b"panic", b"SIGSEGV", b"AddressSanitizer", b"FATAL", b"Bus error", b"abort"]
found = [(k.decode(), d.count(k)) for k in marks if d.count(k)]
print("crash markers:", found if found else "NONE (0)")
