
zig:="zig-0.14.0"

out:=".dim-out"

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
    (behaviour-test "tests/fs/fat32.dis")

behaviour-test script: install
    @mkdir -p {{ join(out, parent_directory(script)) }}
    ./zig-out/bin/dim --output {{ join(out, without_extension(script) + ".img") }} --script "{{script}}" --size 30M

# TODO(fqu):  sfdisk --json .dim-out/tests/part/mbr/basic-single-part-unsized.img

fuzz:
    {{zig}} build install test --fuzz --port 35991
