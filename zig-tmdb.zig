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

    pub fn get(self: TmdbSession, query: Query) !TmdbResponse {
        const response = try self.launchRequest(query.bake(self.alloc));

        // TODO: surely there is a better way of doing this?
        switch (query.response_type) {
            .search_movie => {
                const resp_obj = try self.parseJson(SearchMovieResponse, response);
                return TmdbResponse{ .search_movie = resp_obj };
            },
            .movie_details => {
                const resp_obj = try self.parseJson(MovieDetailsResponse, response);
                return TmdbResponse{ .movie_details = resp_obj };
            },
            .movie_credits => {
                const resp_obj = try self.parseJson(MovieCreditsResponse, response);
                return TmdbResponse{ .movie_credits = resp_obj };
            },
            .movie_external_ids => {
                const resp_obj = try self.parseJson(MovieExternalIdsResponse, response);
                return TmdbResponse{ .movie_external_ids = resp_obj };
            },
        }
    }
};

pub const Field = struct {
    value: QueryValue,
    label: []const u8 = "",
    field_type: FieldType = FieldType.query_param,

    pub fn fromBoolean(params: struct { label: []const u8 = "", val: bool, field_type: FieldType = .query_param }) Field {
        return Field{ .value = QueryValue{ .boolean = params.val }, .label = params.label, .field_type = params.field_type };
    }

    pub fn fromString(params: struct { label: []const u8 = "", val: []const u8, field_type: FieldType = .query_param }) Field {
        return Field{ .value = QueryValue{ .string = params.val }, .label = params.label, .field_type = params.field_type };
    }

    pub fn fromInt(params: struct { label: []const u8 = "", val: u32, field_type: FieldType = .query_param }) Field {
        return Field{ .value = QueryValue{ .int = params.val }, .label = params.label, .field_type = params.field_type };
    }

    pub fn formatLabel(self: Field, allocator: std.mem.Allocator) []const u8 {
        return switch (self.value) {
            .string => |string| string, // TODO: if this is a query parameter, should have certain characters swapped (see: https://en.wikipedia.org/wiki/Percent-encoding)
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

const ResponseType = enum { search_movie, movie_details, movie_credits, movie_external_ids };
pub const TmdbResponse = union(ResponseType) { search_movie: SearchMovieResponse, movie_details: MovieDetailsResponse, movie_credits: MovieCreditsResponse, movie_external_ids: MovieExternalIdsResponse };

pub const Query = struct {
    fields: []Field,
    endpoint: []const u8,
    response_type: ResponseType,

    pub fn bake(self: Query, allocator: std.mem.Allocator) []const u8 {
        var base_string = std.ArrayList(u8).init(allocator);
        var base_writer = base_string.writer();

        var path_params = std.ArrayList(Field).init(allocator);
        path_params.deinit();
        var query_string = std.ArrayList(u8).init(allocator);
        defer query_string.deinit();
        var writer = query_string.writer();
        for (self.fields) |field| {
            switch (field.field_type) {
                .query_param => {
                    const val = field.formatLabel(allocator);
                    defer if (field.requiresDeinit()) allocator.free(val);
                    writer.print("{s}={s}&", .{ field.label, val }) catch unreachable;
                },
                .path_param => {
                    path_params.append(field) catch unreachable;
                },
                else => continue,
            }
        }
        if (query_string.items.len > 0) _ = query_string.pop();

        var i: usize = 0;
        while (i < self.endpoint.len) {
            if (self.endpoint[i] == '{') {
                const end = std.mem.indexOf(u8, self.endpoint[i + 1 ..], "}") orelse unreachable;
                const key = self.endpoint[i + 1 .. i + 1 + end];

                for (path_params.items) |param| {
                    if (std.mem.eql(u8, param.label, key)) {
                        const val = param.formatLabel(allocator);
                        defer if (param.requiresDeinit()) allocator.free(val);
                        _ = base_writer.write(val) catch unreachable;
                        break;
                    }
                }

                i += 1 + end + 1;
            } else {
                _ = base_writer.writeByte(self.endpoint[i]) catch unreachable;
                i += 1;
            }
        }

        // const query_string = toQueryString(allocator, query_params, query_labels) catch unreachable;
        // defer allocator.free(query_string);
        if (query_string.items.len > 0) {
            return std.mem.join(allocator, "?", &.{ base_string.items, query_string.items }) catch unreachable;
        }

        return std.fmt.allocPrint(allocator, "{s}", .{base_string.items}) catch unreachable;
        //const out = try std.fmt.allocPrint(allocator, "{s}", .{self.query});
        //defer allocator.free(out);
        //return try std.mem.join(allocator, "?", &.{ TEMPLATE, out });
    }

    pub fn searchMovie(allocator: std.mem.Allocator, params: struct { query: []const u8, include_adult: bool = false, language: []const u8 = "en-US", primary_release_year: ?u32 = null, page: u32 = 1, region: ?[]u8 = undefined, year: ?u32 = null }) Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        fields.append(Field.fromString(.{ .label = "query", .val = params.query })) catch unreachable;
        fields.append(Field.fromBoolean(.{ .label = "include_adult", .val = params.include_adult })) catch unreachable;
        fields.append(Field.fromString(.{ .label = "language", .val = params.language })) catch unreachable;
        fields.append(Field.fromInt(.{ .label = "page", .val = params.page })) catch unreachable;
        if (params.year != null) fields.append(Field.fromInt(.{ .label = "year", .val = params.year orelse unreachable })) catch unreachable;
        if (params.primary_release_year != null) fields.append(Field.fromInt(.{ .label = "primary_release_year", .val = params.primary_release_year orelse unreachable })) catch unreachable;
        if (params.region != null) fields.append(Field.fromString(.{ .label = "region", .val = params.region orelse unreachable })) catch unreachable;

        return Query{ .fields = std.mem.Allocator.dupe(allocator, Field, fields.items[0..]) catch unreachable, .endpoint = "https://api.themoviedb.org/3/search/movie", .response_type = ResponseType.search_movie };
    }

    pub fn movieDetails(allocator: std.mem.Allocator, params: struct { movie_id: u32, append_to_response: ?[]const u8 = null }) Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param })) catch unreachable;
        if (params.append_to_response != null) fields.append(Field.fromString(.{ .label = "append_to_response", .val = params.append_to_response orelse unreachable })) catch unreachable;

        return Query{ .fields = std.mem.Allocator.dupe(allocator, Field, fields.items[0..]) catch unreachable, .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}", .response_type = ResponseType.movie_details };
    }

    pub fn movieCredits(allocator: std.mem.Allocator, params: struct { movie_id: u32 }) Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param })) catch unreachable;

        return Query{ .fields = std.mem.Allocator.dupe(allocator, Field, fields.items[0..]) catch unreachable, .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}/credits", .response_type = ResponseType.movie_credits };
    }

    pub fn movieExternalIds(allocator: std.mem.Allocator, params: struct { movie_id: u32 }) Query {
        var fields = std.ArrayList(Field).init(allocator);
        defer fields.deinit();
        fields.append(Field.fromInt(.{ .label = "movie_id", .val = params.movie_id, .field_type = FieldType.path_param })) catch unreachable;

        return Query{ .fields = std.mem.Allocator.dupe(allocator, Field, fields.items[0..]) catch unreachable, .endpoint = "https://api.themoviedb.org/3/movie/{movie_id}/external_ids", .response_type = ResponseType.movie_external_ids };
    }
};

pub const FieldType = enum { path_param, query_param, header_param };

const QueryValueTag = enum { int, string, boolean, none };

pub const QueryValue = union(QueryValueTag) { int: u32, string: []const u8, boolean: bool, none };

const Genre = struct { id: u32, name: []u8 };
const ProductionCompany = struct { id: u32, logo_path: ?[]u8, name: []u8, origin_country: []u8 };
const ProductionCountry = struct { iso_3166_1: []u8, name: []u8 };
const SpokenLanguage = struct { english_name: []u8, iso_639_1: []u8, name: []u8 };

const SearchMovieResponseObject = struct { adult: bool, backdrop_path: ?[]u8, genre_ids: []u32, id: u32, original_language: []u8, original_title: []u8, overview: []u8, popularity: f32, poster_path: ?[]u8, release_date: ?[]u8, title: []u8, video: bool, vote_average: f32, vote_count: u32 };
const SearchMovieResponse = struct { page: u32, results: []SearchMovieResponseObject, total_pages: u32, total_results: u32 };

const MovieDetailsResponse = struct { adult: bool, backdrop_path: []u8, belongs_to_collection: ?[]u8, budget: u32, genres: []Genre, homepage: []u8, id: u32, imdb_id: ?[]u8, origin_country: [][]u8, original_language: ?[]u8, original_title: []u8, overview: []u8, popularity: f32, poster_path: ?[]u8, production_companies: []ProductionCompany, production_countries: []ProductionCountry, release_date: ?[]u8, revenue: u32, runtime: u32, spoken_languages: []SpokenLanguage, status: ?[]u8, tagline: ?[]u8, title: []u8, video: bool, vote_average: f32, vote_count: u32, credits: ?MovieCreditsResponse = null, external_ids: ?MovieExternalIdsResponse = null };

const MovieCreditsResponse = struct { id: u32 = 0, cast: []struct { adult: bool = true, gender: u32, id: u32, known_for_department: []u8, name: []u8, original_name: []u8, popularity: f32 = 0, profile_path: ?[]u8, cast_id: u32 = 0, character: []u8, credit_id: []u8, order: u32 = 0 }, crew: []struct { adult: bool = true, gender: u32, id: u32, known_for_department: []u8, name: []u8, original_name: []u8, popularity: f32 = 0, profile_path: ?[]u8, credit_id: []u8, department: []u8, job: []u8 } };
const MovieExternalIdsResponse = struct { id: u32 = 0, imdb_id: ?[]u8, wikidata_id: ?[]u8, facebook_id: ?[]u8, instagram_id: ?[]u8, twitter_id: ?[]u8 };
