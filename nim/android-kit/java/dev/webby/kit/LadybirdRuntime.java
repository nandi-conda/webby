package dev.webby.kit;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.system.ErrnoException;
import android.system.Os;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Lays out what Ladybird expects of a Linux install inside the app's private storage, files/ladybird. The same as the
 * Flutter app's LadybirdRuntime.kt (app/android/app/src/main/kotlin/dev/webby/webby), which explains the layout.
 */
final class LadybirdRuntime {
    private static final String[] HELPERS = {
        "WebContent", "RequestServer", "ImageDecoder", "Compositor", "MediaServer", "WebWorker", "WasmCompiler"
    };

    private LadybirdRuntime() {}

    static File prefix(Context context) {
        return new File(context.getFilesDir(), "ladybird");
    }

    static void setEnvironment(Context context) throws ErrnoException {
        File prefix = prefix(context);
        prefix.mkdirs();
        Os.setenv("HOME", prefix.getPath(), true);
        Os.setenv("XDG_CONFIG_HOME", prefix.getPath(), true);
        String[][] directories = {
            {"XDG_DATA_HOME", "data"}, {"XDG_CACHE_HOME", "cache"}, {"XDG_RUNTIME_DIR", "run"}, {"TMPDIR", "tmp"}
        };
        for (String[] d : directories) {
            File path = new File(prefix, d[1]);
            path.mkdirs();
            Os.setenv(d[0], path.getPath(), true);
        }
        File downloads = new File(context.getFilesDir(), "downloads");
        downloads.mkdirs();
        Os.setenv("XDG_DOWNLOAD_DIR", downloads.getPath(), true);
        String libraries = context.getApplicationInfo().nativeLibraryDir;
        Os.setenv("LD_LIBRARY_PATH", libraries, true);
        Os.setenv("LADYBIRD_CRANELIFT_COMPILER", new File(libraries, "libcranelift-compiler.so").getPath(), true);
        Os.setenv("MIMALLOC_PURGE_DECOMMITS", "1", false);
        Os.setenv("WEBBY_LADYBIRD_ARGS", "--certificate " + new File(prefix, "cacert.pem").getPath(), true);
    }

    /** Unpacks and links everything; returns the prefix to hand to webby_init(). Off the main thread. */
    static String prepare(Context context) throws Exception {
        File prefix = prefix(context);
        PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
        String stamp = info.getLongVersionCode() + " " + info.lastUpdateTime;
        File stampFile = new File(prefix, ".unpacked");
        File resources = new File(prefix, ".lagom");
        if (!resources.isDirectory() || !stampFile.exists() || !read(stampFile).equals(stamp)) {
            deleteRecursively(resources);
            unzip(context, "lagom.zip", resources);
            Files.write(stampFile.toPath(), stamp.getBytes("UTF-8"));
        }
        writeCertificates(new File(prefix, "cacert.pem"));

        File libraryDirectory = new File(context.getApplicationInfo().nativeLibraryDir);
        File libexec = new File(prefix, "libexec");
        libexec.mkdirs();
        new File(prefix, "bin").mkdirs();
        for (String helper : HELPERS) {
            File link = new File(libexec, helper);
            link.delete();
            File binary = new File(libraryDirectory, "lib" + helper + ".so");
            if (binary.exists()) Os.symlink(binary.getPath(), link.getPath());
        }
        return prefix.getPath();
    }

    private static String read(File file) throws IOException {
        return new String(Files.readAllBytes(file.toPath()), "UTF-8");
    }

    private static void deleteRecursively(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteRecursively(child);
        file.delete();
    }

    private static void unzip(Context context, String asset, File destination) throws IOException {
        File partial = new File(destination.getParentFile(), destination.getName() + ".partial");
        deleteRecursively(partial);
        String root = partial.getCanonicalPath() + File.separator;
        byte[] buffer = new byte[1 << 16];
        try (ZipInputStream zip = new ZipInputStream(new BufferedInputStream(context.getAssets().open(asset)))) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                File target = new File(partial, entry.getName());
                if (!target.getCanonicalPath().startsWith(root)) throw new IOException("Bad path in " + asset);
                if (entry.isDirectory()) {
                    target.mkdirs();
                    continue;
                }
                target.getParentFile().mkdirs();
                try (OutputStream out = new BufferedOutputStream(new FileOutputStream(target))) {
                    int n;
                    while ((n = zip.read(buffer)) > 0) out.write(buffer, 0, n);
                }
            }
        }
        if (!partial.renameTo(destination)) throw new IOException("Could not move " + partial + " to " + destination);
    }

    // Android keeps one PEM file per CA; curl wants one bundle.
    private static void writeCertificates(File bundle) throws IOException {
        File directory = null;
        for (String path : new String[] {"/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"}) {
            if (new File(path).isDirectory()) {
                directory = new File(path);
                break;
            }
        }
        if (directory == null) return;
        File[] files = directory.listFiles();
        if (files == null) return;
        Arrays.sort(files);
        File partial = new File(bundle.getPath() + ".partial");
        try (OutputStream out = new BufferedOutputStream(new FileOutputStream(partial))) {
            for (File file : files) {
                out.write(Files.readAllBytes(file.toPath()));
                out.write('\n');
            }
        }
        if (!partial.renameTo(bundle)) throw new IOException("Could not move " + partial + " to " + bundle);
    }
}
