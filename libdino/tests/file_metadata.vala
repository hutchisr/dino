namespace Dino.Test {

class FileMetadataTest : Gee.TestCase {
    private string directory;

    public FileMetadataTest() {
        base("FileMetadata");
        add_test("small_image_thumbnail", test_small_image_thumbnail);
        add_test("large_image_dimensions_without_thumbnail", test_large_image_dimensions_without_thumbnail);
        add_test("corrupt_image_completes_with_error", test_corrupt_image_completes_with_error);
        add_test("missing_file_hash_completes_with_error", test_missing_file_hash_completes_with_error);
    }

    public override void set_up() {
        try {
            directory = DirUtils.make_tmp("dino-file-metadata-XXXXXX");
        } catch (Error e) {
            error("Could not create metadata test directory: %s", e.message);
        }
    }

    public override void tear_down() {
        FileUtils.remove(Path.build_filename(directory, "image.png"));
        DirUtils.remove(directory);
    }

    private File make_image(int width, int height) throws Error {
        string path = Path.build_filename(directory, "image.png");
        var image = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, width, height);
        image.fill(0x336699ff);
        image.save(path, "png");
        return File.new_for_path(path);
    }

    private Xmpp.Xep.FileMetadataElement.FileMetadata read_metadata(File file) throws Error {
        var provider = new ImageFileMetadataProvider();
        var metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();
        var loop = new MainLoop();
        Error? failure = null;
        bool completed = false;
        uint timeout = Timeout.add_seconds(5, () => {
            fail_if_reached("Image metadata did not complete");
            loop.quit();
            return Source.CONTINUE;
        });
        provider.fill_metadata.begin(file, metadata, (_, result) => {
            try {
                provider.fill_metadata.end(result);
            } catch (Error e) {
                failure = e;
            }
            completed = true;
            loop.quit();
        });
        if (!completed) loop.run();
        Source.remove(timeout);
        if (failure != null) throw failure;
        return metadata;
    }

    private void test_small_image_thumbnail() {
        try {
            var metadata = read_metadata(make_image(32, 16));
            fail_if_not_eq_int(metadata.width, 32);
            fail_if_not_eq_int(metadata.height, 16);
            if (fail_if_not_eq_int(metadata.thumbnails.size, 1)) return;
            var thumbnail = metadata.thumbnails[0];
            uint8[] bytes = Base64.decode(thumbnail.uri.substring(thumbnail.uri.index_of(",") + 1));
            var decoded = new Gdk.Pixbuf.from_stream(new MemoryInputStream.from_data(bytes));
            fail_if_not_eq_int(decoded.width, thumbnail.width);
            fail_if_not_eq_int(decoded.height, thumbnail.height);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_large_image_dimensions_without_thumbnail() {
        try {
            var metadata = read_metadata(make_image(4097, 4096));
            fail_if_not_eq_int(metadata.width, 4097);
            fail_if_not_eq_int(metadata.height, 4096);
            fail_if_not_eq_int(metadata.thumbnails.size, 0);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_corrupt_image_completes_with_error() {
        try {
            var file = make_image(32, 16);
            uint8[] bytes;
            FileUtils.get_data(file.get_path(), out bytes);
            // Exercise both header failure and failure after valid dimensions.
            foreach (int length in new int[] { 8, bytes.length / 2 }) {
                FileUtils.set_data(file.get_path(), bytes[0:length]);
                try {
                    read_metadata(file);
                    fail_if_reached("Corrupt PNG was accepted");
                } catch (Error e) {
                    fail_if_not(e is Gdk.PixbufError, e.message);
                }
            }
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_missing_file_hash_completes_with_error() {
        var types = new Gee.ArrayList<ChecksumType>();
        types.add(ChecksumType.SHA256);
        var loop = new MainLoop();
        bool completed = false;
        uint timeout = Timeout.add_seconds(5, () => {
            fail_if_reached("File hashing did not complete");
            loop.quit();
            return Source.CONTINUE;
        });
        compute_file_hashes.begin(File.new_for_path(Path.build_filename(directory, "missing")), types, (_, result) => {
            try {
                compute_file_hashes.end(result);
                fail_if_reached("Missing file was hashed successfully");
            } catch (Error e) {
                fail_if_not(e is IOError.NOT_FOUND, e.message);
            }
            completed = true;
            loop.quit();
        });
        if (!completed) loop.run();
        Source.remove(timeout);
    }
}

}
