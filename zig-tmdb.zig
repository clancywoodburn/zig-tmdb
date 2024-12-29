const std = @import("std");

pub const TmdbSession = struct {
    token: []const u8,
    alloc: std.mem.Allocator,

    pub fn init(token: []const u8, alloc: std.mem.Allocator) TmdbSession {
        return TmdbSession{ .token = token, .alloc = alloc };
    }

    fn parseJson(self: TmdbSession, comptime T: type, json_str: []const u8) !T {
        const parsed = try std.json.parseFromSlice(T, self.alloc, json_str, .{});

        const resp = parsed.value;

        return resp;
    }

    fn launchRequest(self: TmdbSession, uri_str: []const u8) ![]const u8 {
        // Make HTTP Client
        var client = std.http.Client{ .allocator = self.alloc };

        // Allocate buffer for headers
        var head_buf: [4096]u8 = undefined;

        // Start HTTP request
        const uri = try std.Uri.parse(uri_str);
        const auth = try std.mem.join(self.alloc, "", &.{ "Authorization: Bearer ", self.token });
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &head_buf, .headers = .{ .authorization = .{ .override = auth } } });

        // Send HTTP Req
        try req.send();
        // Finish body of HTTP req
        try req.finish();

        // Wait for response and parse headers
        try req.wait();

        // Check HTTP status code
        if (req.response.status != std.http.Status.ok) {
            return error.WrongStatusResponse;
        }

        // Read the body
        var body_buf: [1048576]u8 = undefined;

        const body_len = try req.readAll(&body_buf);

        return body_buf[0..body_len];
    }

    pub fn searchForMovie(self: TmdbSession, title: []const u8) !SearchMovieResponse {
        const ENDPOINT = "https://api.themoviedb.org/3/search/movie";

        const end_headed = try std.mem.join(self.alloc, "", &.{ ENDPOINT, "?query=", title });

        const response = try self.launchRequest(end_headed);

        const response_object = try self.parseJson(SearchMovieResponse, response);
        return response_object;
    }

    pub fn getMovieDetails(self: TmdbSession, movie_id: u32) !MovieDetailsResponse {
        const ENDPOINT = "https://api.themoviedb.org/3/movie/";

        const end_headed = try std.fmt.allocPrint(self.alloc, "{s}{d}", .{ ENDPOINT, movie_id });

        const response = try self.launchRequest(end_headed);
        std.debug.print("{s}\n", .{response});
        const response_object = try self.parseJson(MovieDetailsResponse, response);
        return response_object;
    }

    pub fn get(self: TmdbSession, query: Query) !TmdbResponse {
        const response = try self.launchRequest(query.bake(self.alloc));

        switch (query.response_type) {
            .search_movie => {
                const resp_obj = try self.parseJson(SearchMovieResponse, response);
                return TmdbResponse{ .search_movie = resp_obj };
            },
        }
    }
};

pub fn boolToStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

pub fn yearToStr(y: ?u32) ?[]const u8 {
    std.debug.print("YEAR TO STR CALL FOR: {any}\n", .{y});
    if (y == null) return null;
    std.debug.print("MUST NOT BE NULL NOW!\n", .{});
    var buf: [12]u8 = undefined;
    const fmat = std.fmt.bufPrint(&buf, "{d}", .{y orelse unreachable}) catch unreachable;
    std.debug.print("FMAT IS {s}\n", .{fmat});
    return fmat[0..];
    // return &buf;
}

pub const Field = struct {
    value: QueryValue,
    label: []const u8 = "",
    field_type: FieldType = FieldType.query_param,

    pub fn fromBoolean(label: []const u8, val: bool) Field {
        const f_t = FieldType.query_param;
        return Field{ .value = QueryValue{ .boolean = val }, .label = label, .field_type = f_t };
    }

    pub fn fromString(label: []const u8, val: []const u8) Field {
        const f_t = FieldType.query_param;
        return Field{ .value = QueryValue{ .string = val }, .label = label, .field_type = f_t };
    }

    pub fn fromInt(label: []const u8, val: u32) Field {
        const f_t = FieldType.query_param;
        return Field{ .value = QueryValue{ .int = val }, .label = label, .field_type = f_t };
    }

    pub fn formatLabel(self: Field, allocator: std.mem.Allocator) []const u8 {
        return switch (self.value) {
            .string => |string| string,
            .boolean => |boolean| if (boolean) "true" else "false",
            .int => |int| std.fmt.allocPrint(allocator, "{d}", .{int}) catch unreachable,
            else => "",
        };
    }

    pub fn requiresDeinit(self: Field) bool {
        return switch (self.value) {
            .int => true,
            else => false,
        };
    }
};

const ResponseType = enum { search_movie };
const TmdbResponse = union(ResponseType) { search_movie: SearchMovieResponse };

pub const Query = struct {
    fields: []Field,
    endpoint: []const u8,
    response_type: ResponseType,

    pub fn bake(self: Query, allocator: std.mem.Allocator) []const u8 {
        var query_string = std.ArrayList(u8).init(allocator);
        defer query_string.deinit();
        var writer = query_string.writer();
        for (self.fields) |field| {
            if (field.field_type == FieldType.query_param) {
                const val = field.formatLabel(allocator);
                defer if (field.requiresDeinit()) allocator.free(val);
                writer.print("{s}={s}&", .{ field.label, val }) catch unreachable;
            }
        }
        _ = query_string.pop();
        // const query_string = toQueryString(allocator, query_params, query_labels) catch unreachable;
        // defer allocator.free(query_string);
        if (query_string.items.len > 0) {
            return std.mem.join(allocator, "?", &.{ self.endpoint, query_string.items }) catch unreachable;
        }

        return std.fmt.allocPrint(allocator, "{s}", .{self.endpoint}) catch unreachable;
        //const out = try std.fmt.allocPrint(allocator, "{s}", .{self.query});
        //defer allocator.free(out);
        //return try std.mem.join(allocator, "?", &.{ TEMPLATE, out });
    }
};

pub fn searchMovieQuery(allocator: std.mem.Allocator, params: struct { query: []const u8, include_adult: bool = false, language: []const u8 = "en-US", primary_release_year: ?u32 = null, page: u32 = 1, region: ?[]u8 = undefined, year: ?u32 = null }) Query {
    var fields = std.ArrayList(Field).init(allocator);
    defer fields.deinit();
    fields.append(Field.fromString("query", params.query)) catch unreachable;
    fields.append(Field.fromBoolean("include_adult", params.include_adult)) catch unreachable;
    fields.append(Field.fromString("language", params.language)) catch unreachable;
    fields.append(Field.fromInt("page", params.page)) catch unreachable;
    if (params.year != null) fields.append(Field.fromInt("year", params.year orelse unreachable)) catch unreachable;
    if (params.primary_release_year != null) fields.append(Field.fromInt("primary_release_year", params.primary_release_year orelse unreachable)) catch unreachable;
    if (params.region != null) fields.append(Field.fromString("region", params.region orelse unreachable)) catch unreachable;

    return Query{ .fields = std.mem.Allocator.dupe(allocator, Field, fields.items[0..]) catch unreachable, .endpoint = "https://api.themoviedb.org/3/search/movie", .response_type = ResponseType.search_movie };
}

pub const FieldType = enum { path_param, query_param, header_param };

const QueryValueTag = enum { int, string, boolean, none };

pub const QueryValue = union(QueryValueTag) { int: u32, string: []const u8, boolean: bool, none };

pub const SearchMovieQuery = struct {
    return_type: type = SearchMovieResponse,
    query: []const u8,
    include_adult: bool = false,
    language: []const u8 = "en-US",
    primary_release_year: ?u32 = undefined,
    page: u32 = 1,
    region: ?[]u8 = undefined,
    year: ?u32 = undefined,

    // pub fn bake(self: SearchMovieQuery, allocator: std.mem.Allocator) []const u8 {
    //     const TEMPLATE = "https://api.themoviedb.org/3/search/movie";
    //     std.debug.print("{any}\n", .{self.primary_release_year});
    //     const pry: ?[]u8 = blk: {
    //         if (self.primary_release_year == null) {
    //             break :blk null;
    //         } else {
    //             const v = std.fmt.allocPrint(allocator, "{d}", .{self.primary_release_year orelse unreachable}) catch unreachable;
    //             // std.debug.print("{s}", .{v});
    //             break :blk v;
    //         }
    //     };
    //     defer if (pry != null) allocator.free(pry orelse unreachable);
    //     std.debug.print("{any}", .{pry});
    //
    //     const pg = std.fmt.allocPrint(allocator, "{d}", .{self.page}) catch unreachable;
    //     defer allocator.free(pg);
    //     const query_params = &.{ self.query, boolToStr(self.include_adult), self.language, pry, pg, self.region, yearToStr(self.year) };
    //     const query_labels = &.{ "query", "include_adult", "language", "primary_release_year", "page", "region", "year" };
    //
    //     const query_string = toQueryString(allocator, query_params, query_labels) catch unreachable;
    //     defer allocator.free(query_string);
    //     if (query_string.len > 0) {
    //         return std.mem.join(allocator, "?", &.{ TEMPLATE, query_string }) catch unreachable;
    //     }
    //
    //     return std.fmt.allocPrint(allocator, "{s}", .{TEMPLATE}) catch unreachable;
    //     //const out = try std.fmt.allocPrint(allocator, "{s}", .{self.query});
    //     //defer allocator.free(out);
    //     //return try std.mem.join(allocator, "?", &.{ TEMPLATE, out });
    // }
};

// pub fn toQueryString(allocator: std.mem.Allocator, fields: []Field) ![]u8 {
//     std.debug.print("{s}\n", .{"here1"});
//     var output = std.ArrayList(u8).init(allocator);
//     defer output.deinit();
//     var writer = output.writer();
//     for (query_params, query_labels) |p, l| {
//         if (p == null) {
//             continue;
//         }
//         std.debug.print("{s} AND {s}\n", .{ l orelse unreachable, p orelse unreachable });
//         _ = try writer.print("{s}={s}&", .{ l orelse "", p orelse unreachable });
//     }
//     _ = output.pop();
//
//     return std.mem.Allocator.dupe(allocator, u8, output.items[0..]);
// }

const TmdbQuery = struct {
    url: []u8,
    return_type: type,

    pub fn init() !TmdbQuery {}
};

const Genre = struct { id: u32, name: []u8 };
const ProductionCompany = struct { id: u32, logo_path: ?[]u8, name: []u8, origin_country: []u8 };
const ProductionCountry = struct { iso_3166_1: []u8, name: []u8 };
const SpokenLanguage = struct { english_name: []u8, iso_639_1: []u8, name: []u8 };

const SearchMovieResponseObject = struct { adult: bool, backdrop_path: ?[]u8, genre_ids: []u32, id: u32, original_language: []u8, original_title: []u8, overview: []u8, popularity: f32, poster_path: ?[]u8, release_date: ?[]u8, title: []u8, video: bool, vote_average: f32, vote_count: u32 };

const SearchMovieResponse = struct { page: u32, results: []SearchMovieResponseObject, total_pages: u32, total_results: u32 };

const MovieDetailsResponse = struct { adult: bool, backdrop_path: []u8, belongs_to_collection: ?[]u8, budget: u32, genres: []Genre, homepage: []u8, id: u32, imdb_id: ?[]u8, origin_country: [][]u8, original_language: ?[]u8, original_title: []u8, overview: []u8, popularity: f32, poster_path: ?[]u8, production_companies: []ProductionCompany, production_countries: []ProductionCountry, release_date: ?[]u8, revenue: u32, runtime: u32, spoken_languages: []SpokenLanguage, status: ?[]u8, tagline: ?[]u8, title: []u8, video: bool, vote_average: f32, vote_count: u32 };

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const q = searchMovieQuery(allocator, .{ .query = "Hello" });
    std.debug.print("{any}", .{q});
    defer allocator.free(q.fields);
}
