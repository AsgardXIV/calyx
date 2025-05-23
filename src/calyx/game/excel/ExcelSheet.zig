const std = @import("std");
const Allocator = std.mem.Allocator;

const ExcelHeader = @import("ExcelHeader.zig");
const ExcelPage = @import("ExcelPage.zig");
const ExcelRow = @import("ExcelRow.zig");
const ExcelModule = @import("ExcelModule.zig");

const native_types = @import("native_types.zig");
const ExcelDataOffset = native_types.ExcelDataOffset;
const ExcelDataRowPreamble = native_types.ExcelDataRowPreamble;
const ExcelPageDefinition = native_types.ExcelPageDefinition;

const Pack = @import("../sqpack/Pack.zig");
const Language = @import("../common/language.zig").Language;

const ExcelSheet = @This();

const RawRowData = struct {
    data: []const u8,
    row_count: u16,
};

allocator: Allocator,
module: *ExcelModule,
sheet_name: []const u8,
excel_header: *ExcelHeader,
language: Language,
pages: []?*ExcelPage,

pub fn init(allocator: Allocator, module: *ExcelModule, sheet_name: []const u8, preferred_language: Language) !*ExcelSheet {
    const sheet = try allocator.create(ExcelSheet);
    errdefer allocator.destroy(sheet);

    const sheet_name_dupe = try allocator.dupe(u8, sheet_name);
    errdefer allocator.free(sheet_name_dupe);

    sheet.* = .{
        .allocator = allocator,
        .module = module,
        .sheet_name = sheet_name_dupe,
        .excel_header = undefined,
        .language = undefined,
        .pages = undefined,
    };

    // Load the excel header
    try sheet.loadExcelHeader();
    errdefer sheet.excel_header.deinit();

    // Determine the actual language to use
    try sheet.determineLanguage(preferred_language);

    // Allocate the pages array
    try sheet.allocatePages();
    errdefer sheet.cleanupPages();

    return sheet;
}

pub fn deinit(sheet: *ExcelSheet) void {
    sheet.cleanupPages();
    sheet.excel_header.deinit();
    sheet.allocator.free(sheet.sheet_name);
    sheet.allocator.destroy(sheet);
}

/// Gets the row data for a row.
///
/// `row_id` is the row id of the row to get.
///
/// Both default and subrow sheets are supported.
/// See `ExcelRow` for more details on how to access columns and subrows.
///
/// No heap allocations are performed in this function.
/// The returned data is valid until the sheet is deinitialized.
pub fn getRow(sheet: *ExcelSheet, row_id: u32) !ExcelRow {
    // TODO: Do we need an alloc version of this method?

    const page, const offset = try sheet.determineRowPageAndOffset(row_id);
    return sheet.rawRowFromPageAndOffset(page, offset);
}

/// Gets the row data for a row index.
///
/// `index` is the absolute index of the row to get.
/// This is a linear index across all pages and is not related to the row_id.
/// In most cases, you should use `getRow` instead of this function.
/// For scanning a sheet you should prefer using `rowIterator` as it is significantly more efficient.
///
/// No heap allocations are performed in this function.
/// The returned data is valid until the sheet is deinitialized.
pub fn getRowAtIndex(sheet: *ExcelSheet, index: usize) !ExcelRow {
    var index_total: usize = 0;
    for (sheet.excel_header.page_definitions, 0..) |page_def, i| {
        const page_end = index_total + page_def.row_count;
        if (index < page_end) {
            const page = try sheet.getPageData(i);
            const page_row_index = index - index_total;
            return sheet.rawRowFromPageAndOffset(page, page.indexes[page_row_index]);
        }
        index_total = page_end;
    }

    return error.RowNotFound;
}

/// Gets an iterator for the rows in the sheet.
/// The iterator will iterate over all the rows in the sheet.
///
/// No heap allocations are performed in this function.
/// The returned iterator is valid until the sheet is deinitialized or the iterator is used.
pub fn rowIterator(sheet: *ExcelSheet) RowIterator {
    return .{
        .sheet = sheet,
        .page_index = 0,
        .row_index = 0,
    };
}

/// Gets the number of rows in the sheet.
/// This includes all pages but does not include subrows.
///
/// Because rows can be missing, you should not call `getRow` based on this value.
/// Instead use `getRowAtIndex` or `rowIterator`.
///
/// No heap allocations are performed in this function.
pub fn getRowCount(sheet: *ExcelSheet) usize {
    var count: usize = 0;
    for (sheet.excel_header.page_definitions) |page| {
        count += page.row_count;
    }
    return count;
}

fn rawRowFromPageAndOffset(sheet: *ExcelSheet, page: *ExcelPage, offset: ExcelDataOffset) !ExcelRow {
    var fbs = std.io.fixedBufferStream(page.raw_sheet_data);

    const true_offset = offset.offset - page.data_start;
    fbs.pos = true_offset;

    const row_preamble = try fbs.reader().readStructEndian(ExcelDataRowPreamble, .big);

    const row_buffer = page.raw_sheet_data[fbs.pos..][0..row_preamble.data_size];

    return .{
        .sheet = sheet,
        .row_id = offset.row_id,
        .sub_row_count = row_preamble.row_count,
        .data = row_buffer,
    };
}

fn determineRowPageAndOffset(sheet: *ExcelSheet, row_id: u32) !struct { *ExcelPage, ExcelDataOffset } {
    const page_index = try sheet.determineRowPage(row_id);
    const data = try sheet.getPageData(page_index);

    // First we see if we can just index directly
    const direct_index = row_id - sheet.excel_header.page_definitions[page_index].start_id;
    if (direct_index < data.indexes.len) {
        const idx = data.indexes[direct_index];
        if (idx.row_id == row_id) {
            return .{ data, idx };
        }
    }

    // If not, we need to use the map
    const row_index_id = data.row_to_index.get(row_id) orelse return error.RowNotFound;
    const row_offset = data.indexes[row_index_id];

    return .{ data, row_offset };
}

fn determineRowPage(sheet: *ExcelSheet, row_id: u32) !usize {
    const S = struct {
        fn pageFind(inner_row_id: u32, page: ExcelPageDefinition) std.math.Order {
            if (inner_row_id < page.start_id) return .lt;
            if (inner_row_id >= page.start_id + page.row_count) return .gt;
            return .eq;
        }
    };

    const index = std.sort.binarySearch(ExcelPageDefinition, sheet.excel_header.page_definitions, row_id, S.pageFind);

    return index orelse error.RowNotFound;
}

fn getPageData(sheet: *ExcelSheet, page_index: usize) !*ExcelPage {
    if (page_index >= sheet.pages.len) {
        @branchHint(.unlikely);
        return error.InvalidPageIndex;
    }

    if (sheet.pages[page_index] == null) {
        @branchHint(.unlikely);
        const data = try sheet.loadPageData(sheet.excel_header.page_definitions[page_index].start_id);
        sheet.pages[page_index] = data;
        return data;
    }

    return sheet.pages[page_index].?;
}

fn loadPageData(sheet: *ExcelSheet, start_row_id: u32) !*ExcelPage {
    var sfb = std.heap.stackFallback(1024, sheet.allocator);
    const sfa = sfb.get();

    const sheet_path = blk: {
        if (sheet.language == Language.none) {
            break :blk try std.fmt.allocPrint(sfa, "exd/{s}_{d}.exd", .{ sheet.sheet_name, start_row_id });
        } else {
            break :blk try std.fmt.allocPrint(sfa, "exd/{s}_{d}_{s}.exd", .{ sheet.sheet_name, start_row_id, sheet.language.toLanguageString() });
        }
    };
    defer sfa.free(sheet_path);

    const data = try sheet.module.pack.getTypedFile(sheet.allocator, ExcelPage, sheet_path);
    errdefer data.deinit();

    return data;
}

fn loadExcelHeader(sheet: *ExcelSheet) !void {
    var sfb = std.heap.stackFallback(1024, sheet.allocator);
    const sfa = sfb.get();

    const sheet_path = try std.fmt.allocPrint(sfa, "exd/{s}.exh", .{sheet.sheet_name});
    defer sfa.free(sheet_path);

    const excel_header = try sheet.module.pack.getTypedFile(sheet.allocator, ExcelHeader, sheet_path);
    errdefer excel_header.deinit();

    sheet.excel_header = excel_header;
}

fn determineLanguage(sheet: *ExcelSheet, preferred_language: Language) !void {
    var has_none = false;

    // Try to use the preferred language first
    for (sheet.excel_header.languages) |language| {
        if (language == preferred_language) {
            sheet.language = language;
            return;
        }

        if (language == .none) {
            has_none = true;
        }
    }

    // If the preferred language is not found, use none if available
    if (has_none) {
        sheet.language = .none;
        return;
    }

    // If no compatibile language is found, return an error
    return error.LanguageNotFound;
}

fn allocatePages(sheet: *ExcelSheet) !void {
    const num_pages = sheet.excel_header.page_definitions.len;
    sheet.pages = try sheet.allocator.alloc(?*ExcelPage, num_pages);
    errdefer sheet.allocator.free(sheet.pages);

    for (sheet.pages) |*data| {
        data.* = null;
    }
}

fn cleanupPages(sheet: *ExcelSheet) void {
    for (sheet.pages) |*data| {
        if (data.*) |d| {
            d.deinit();
        }
        data.* = null;
    }
    sheet.allocator.free(sheet.pages);
}

pub const RowIterator = struct {
    sheet: *ExcelSheet,
    page_index: usize,
    row_index: usize,

    /// Returns the next row in the sheet or null if there are no more rows
    pub fn next(self: *@This()) ?ExcelRow {
        const data = self.sheet.getPageData(self.page_index) catch return null;

        if (self.row_index >= data.indexes.len) {
            @branchHint(.unlikely);
            return null;
        }

        const row = self.sheet.rawRowFromPageAndOffset(data, data.indexes[self.row_index]) catch return null;

        self.row_index += 1;

        if (self.row_index >= data.indexes.len) {
            self.page_index += 1;
            self.row_index = 0;
        }

        return row;
    }
};
