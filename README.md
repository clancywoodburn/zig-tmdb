# zig-tmdb
A wrapper for the TMDB API written in Zig.

## Usage
To use this code, first create a new zig project in the command line and run the following

```
zig init
mkdir libs
cd libs
git clone https://github.com/clancywoodburn/zig-tmdb.git
```

Then, inside of `build.zig` add the following:

```zig
const zig_tmdb = b.addModule("zig-tmdb", .{
    .root_source_file = b.path("libs/zig-tmdb/zig-tmdb.zig")
});
```

Inside of `main.zig`, add `const zig_tmdb = @import("zig-tmdb);`.

The wrapper may now be used, and run using `zig build run`.
