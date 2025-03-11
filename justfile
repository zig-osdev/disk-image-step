
zig:="zig-0.14.0"

default: install test

install:
    {{zig}} build install

test: unit-test behaviour-tests

unit-test:
    {{zig}} build test

behaviour-tests: \
    (behaviour-test "tests/basic/empty.dis") \
    (behaviour-test "tests/basic/fill-0x00.dis") \
    (behaviour-test "tests/basic/fill-0xAA.dis") \
    (behaviour-test "tests/basic/fill-0xFF.dis") \
    (behaviour-test "tests/basic/raw.dis") \
    (behaviour-test "tests/part/mbr/minimal.dis") \
    (behaviour-test "tests/part/mbr/no-part-bootloader.dis") \
    (behaviour-test "tests/part/mbr/basic-single-part-sized.dis") \
    (behaviour-test "tests/part/mbr/basic-single-part-unsized.dis")

behaviour-test script: install
    ./zig-out/bin/dim --output .zig-cache/disk.img --script "{{script}}" --size 30M


fuzz:
    {{zig}} build install test --fuzz --port 35991
