const std = @import("std");

pub const TmdbSession = struct {
    token: []const u8,
    alloc: std.mem.Allocator,

    pub fn init(token: []const u8, alloc: std.mem.Allocator) TmdbSession {
        return TmdbSession{ .token = token, .alloc = alloc };
    }

    fn parseJson(allocator: std.mem.Allocator, comptime T: type, json_str: []const u8) !T {
        const parsed = try std.json.parseFromSlice(T, allocator, json_str, .{});

        defer parsed.deinit();
        return parsed.value;
    }

    fn launchRequest(self: TmdbSession, allocator: std.mem.Allocator, uri_str: []const u8) ![]const u8 {
        // Make HTTP Client
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        // Allocate buffer for headers
        var head_buf: [4096]u8 = undefined;

        // Start HTTP request
        const uri = try std.Uri.parse(uri_str);
        const auth = try std.mem.join(allocator, "", &.{ "Authorization: Bearer ", self.token });
        defer allocator.free(auth);
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &head_buf, .headers = .{ .authorization = .{ .override = auth } } });
        defer req.deinit();
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
        var body_buf: [262144]u8 = undefined;

        const body_len = try req.readAll(&body_buf);

        return body_buf[0..body_len];
    }

    pub fn get(self: TmdbSession, allocator: std.mem.Allocator, query: Query) !TmdbResponse {
        const q = try query.bake(allocator);
        defer allocator.free(q);
        const response = try self.launchRequest(allocator, q);

        switch (query.response_type) {
            .search_movie => {
                const resp_obj = try std.json.parseFromSlice(SearchMovieResponse, allocator, response, .{});
                return TmdbResponse{ .search_movie = resp_obj };
            },
            .movie_details => {
                const resp_obj = try std.json.parseFromSlice(MovieDetailsResponse, allocator, response, .{});
                return TmdbResponse{ .movie_details = resp_obj };
            },
            .movie_credits => {
                const resp_obj = try std.json.parseFromSlice(MovieCreditsResponse, allocator, response, .{});
                return TmdbResponse{ .movie_credits = resp_obj };
            },
            .movie_external_ids => {
                const resp_obj = try std.json.parseFromSlice(MovieExternalIdsResponse, allocator, response, .{});
                return TmdbResponse{ .movie_external_ids = resp_obj };
            },
            .movie_keywords => {
                const resp_obj = try std.json.parseFromSlice(MovieKeywordsResponse, allocator, response, .{});
                return TmdbResponse{ .movie_keywords = resp_obj };
            },
        }
    }
};

fn isValidUnencoded(c: u8) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z', '-', '.', '_', '~' => true,
        else => false,
    };
}

pub const Field = struct {
    value: QueryValue,
    label: []const u8 = "",
    field_type: FieldType = FieldType.query_param,

    pub fn fromBoolean(params: struct { label: []const u8 = "", val: bool, field_type: FieldType = .query_param }) Field {
        return Field{ .value = QueryValue{ .boolean = params.val }, .label = params.label, .field_type = params.field_type };
    }

    pub fn fromString(allocator: std.mem.Allocator, params: struct { label: []const u8 = "", val: []const u8, field_type: FieldType = .query_param }) !Field {
        return Field{ .value = QueryValue{ .string = try std.mem.Allocator.dupe(allocator, u8, params.val) }, .label = params.label, .field_type = params.field_type };
    }

    pub fn fromInt(params: struct { label: []const u8 = "", val: u32, field_type: FieldType = .query_param }) Field {
        return Field{ .value = QueryValue{ .int = params.val }, .label = params.label, .field_type = params.field_type };
    }

    pub fn formatLabel(self: Field, allocator: std.mem.Allocator) ![]const u8 {
        switch (self.value) {
            .string => |string| {
                if (self.field_type != .query_param) return string;
                var encoded_string = std.ArrayList(u8).init(allocator);
                defer encoded_string.deinit();
                try std.Uri.Component.percentEncode(encoded_string.writer(), string, isValidUnencoded);
                return try std.mem.Allocator.dupe(allocator, u8, encoded_string.items);
            },
            .boolean => |boolean| return if (boolean) "true" else "false",
            .int => |int| return try std.fmt.allocPrint(allocator, "{d}", .{int}),
            else => return "",
        }
    }

    pub fn deinit(self: Field, allocator: std.mem.Allocator) void {
        switch (self.value) {
            .string => |string| {
                allocator.free(string);
            },
            else => {},
        }
    }

    pub fn requiresDeinit(self: Field) bool {
        return switch (self.value) {
            .int => true,
            .string => self.field_type == .query_param,
            else => false,
        };
    }
};

const ResponseType = enum { search_movie, movie_details, movie_credits, movie_external_ids, movie_keywords };
pub const TmdbResponse = union(ResponseType) { search_movie: std.json.Parsed(SearchMovieResponse), movie_details: std.json.Parsed(MovieDetailsResponse), movie_credits: std.json.Parsed(MovieCreditsResponse), movie_external_ids: std.json.Parsed(MovieExternalIdsResponse), movie_keywords: std.json.Parsed(MovieKeywordsResponse) };

pub const Query = struct {
    fields: []Field,
    endpoint: []const u8,
    response_type: ResponseType,

    pub fn bake(self: Query, allocator: std.mem.Allocator) ![]const u8 {
        var base_string = std.ArrayList(u8).init(allocator);
        defer base_string.deinit();
        var base_writer = base_string.writer();

        var path_params = std.ArrayList(Field).init(allocator);
        defer path_params.deinit();
        var query_string = std.ArrayList(u8).init(allocator);
        defer query_string.deinit();
        var writer = query_string.writer();
        for (self.fields) |field| {
            switch (field.field_type) {
                .query_param => {
                    const val = try field.formatLabel(allocator);
                    defer if (field.requiresDeinit()) allocator.free(val);
                    try writer.print("{s}={s}&", .{ field.label, val });
                },
                .path_param => {
                    try path_params.append(field);
                },
                else => continue,
            }
        }
        if (query_string.items.len > 0) _ = query_string.pop();

        var i: usize = 0;
        while (i < self.endpoint.len) {
            if (self.endpoint[i] == '{') {
                const end = std.mem.indexOf(u8, self.endpoint[i + 1 ..], "}") orelse return error.BracketMismatch;
                const key = self.endpoint[i + 1 .. i + 1 + end];

                for (path_params.items) |param| {
                    if (std.mem.eql(u8, param.label, key)) {
                        const val = try param.formatLabel(allocator);
                        defer if (param.requiresDeinit()) allocator.free(val);
                        _ = try base_writer.write(val);
                        break;
                    }
                }

                i += 1 + end + 1;
            } else {
                _ = try base_writer.writeByte(self.endpoint[i]);
                i += 1;
            }
        }

        if (query_string.items.len > 0) {
            return try std.mem.join(allocator, "?", &.{ base_string.items, query_string.items });
        }

        return try std.fmt.allocPrint(allocator, "{s}", .{base_string.items});
    }

    pub fn deinit(self: Query, allocator: std.mem.Allocator) void {
        for (self.fields) |field| {
            field.deinit(allocator);
        }
        allocator.free(self.fields);
    }

    pub fn searchMovie(allocator: std.mem.Allocator, params: struct { query: []const u8, include_adult: bool = false, language: []const u8 = "en-US", primary_release_year: ?u32 = null, page: u32 = 1, region: ?[]u8 = null, year: ?u32 = null }) !Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        try fields.append(try Field.fromString(allocator, .{ .label = "query", .val = params.query }));
        try fields.append(Field.fromBoolean(.{ .label = "include_adult", .val = params.include_adult }));
        try fields.append(try Field.fromString(allocator, .{ .label = "language", .val = params.language }));
        try fields.append(Field.fromInt(.{ .label = "page", .val = params.page }));
        if (params.year) |y| try fields.append(Field.fromInt(.{ .label = "year", .val = y }));
        if (params.primary_release_year) |pry| try fields.append(Field.fromInt(.{ .label = "primary_release_year", .val = pry }));
        if (params.region) |r| try fields.append(try Field.fromString(allocator, .{ .label = "region", .val = r }));

        return Query{ .fields = try std.mem.Allocator.dupe(allocator, Field, fields.items[0..]), .endpoint = "https://api.themoviedb.org/3/search/movie", .response_type = ResponseType.search_movie };
    }

    pub fn movieDetails(allocator: std.mem.Allocator, params: struct { movie_id: u32, append_to_response: ?[]const u8 = null }) !Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        try fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param }));
        if (params.append_to_response) |atr| try fields.append(try Field.fromString(allocator, .{ .label = "append_to_response", .val = atr }));

        return Query{ .fields = try std.mem.Allocator.dupe(allocator, Field, fields.items[0..]), .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}", .response_type = ResponseType.movie_details };
    }

    pub fn movieCredits(allocator: std.mem.Allocator, params: struct { movie_id: u32 }) !Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        try fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param }));

        return Query{ .fields = try std.mem.Allocator.dupe(allocator, Field, fields.items[0..]), .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}/credits", .response_type = ResponseType.movie_credits };
    }

    pub fn movieExternalIds(allocator: std.mem.Allocator, params: struct { movie_id: u32 }) !Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        try fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param }));

        return Query{ .fields = try std.mem.Allocator.dupe(allocator, Field, fields.items[0..]), .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}/external_ids", .response_type = ResponseType.movie_external_ids };
    }

    pub fn movieKeywords(allocator: std.mem.Allocator, params: struct { movie_id: u32 }) !Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        try fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param }));

        return Query{ .fields = try std.mem.Allocator.dupe(allocator, Field, fields.items[0..]), .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}/credits", .response_type = ResponseType.movie_keywords };
    }
};

pub const FieldType = enum { path_param, query_param, header_param };

const QueryValueTag = enum { int, string, boolean, none };

pub const QueryValue = union(QueryValueTag) { int: u32, string: []const u8, boolean: bool, none };

const Genre = struct { id: u32, name: []u8 };
const ProductionCompany = struct { id: u32, logo_path: ?[]u8, name: []u8, origin_country: []u8 };
const ProductionCountry = struct { iso_3166_1: []u8, name: []u8 };
const SpokenLanguage = struct { english_name: []u8, iso_639_1: []u8, name: []u8 };
const Collection = struct { id: u32, name: []u8, poster_path: ?[]u8, backdrop_path: []u8 };

const SearchMovieResponseObject = struct { adult: bool, backdrop_path: ?[]u8, genre_ids: []u32, id: u32, original_language: []u8, original_title: []u8, overview: []u8, popularity: f32, poster_path: ?[]u8, release_date: ?[]u8, title: []u8, video: bool, vote_average: f32, vote_count: u32 };
const SearchMovieResponse = struct { page: u32, results: []SearchMovieResponseObject, total_pages: u32, total_results: u32 };

const MovieDetailsResponse = struct { adult: bool, backdrop_path: ?[]u8, belongs_to_collection: ?Collection, budget: u32, genres: []Genre, homepage: ?[]u8, id: u32, imdb_id: ?[]u8, origin_country: [][]u8, original_language: ?[]u8, original_title: []u8, overview: []u8, popularity: f32, poster_path: ?[]u8, production_companies: []ProductionCompany, production_countries: []ProductionCountry, release_date: ?[]u8, revenue: u32, runtime: u32, spoken_languages: []SpokenLanguage, status: ?[]u8, tagline: ?[]u8, title: []u8, video: bool, vote_average: f32, vote_count: u32, credits: ?MovieCreditsResponse = null, external_ids: ?MovieExternalIdsResponse = null, keywords: ?MovieKeywordsResponse = null };

const MovieCreditsResponse = struct { id: u32 = 0, cast: []struct { adult: bool = true, gender: u32, id: u32, known_for_department: []u8, name: []u8, original_name: []u8, popularity: f32 = 0, profile_path: ?[]u8, cast_id: u32 = 0, character: []u8, credit_id: []u8, order: u32 = 0 }, crew: []struct { adult: bool = true, gender: u32, id: u32, known_for_department: []u8, name: []u8, original_name: []u8, popularity: f32 = 0, profile_path: ?[]u8, credit_id: []u8, department: []u8, job: []u8 } };
const MovieExternalIdsResponse = struct { id: u32 = 0, imdb_id: ?[]u8, wikidata_id: ?[]u8, facebook_id: ?[]u8, instagram_id: ?[]u8, twitter_id: ?[]u8 };
const MovieKeywordsResponse = struct { id: u32 = 0, keywords: []struct { id: u32 = 0, name: []const u8 } };
