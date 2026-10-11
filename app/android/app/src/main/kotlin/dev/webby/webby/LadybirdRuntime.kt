package dev.webby.webby

import android.content.Context
import android.system.Os
import java.io.File
import java.io.IOException
import java.util.zip.ZipInputStream

/**
 * Lays out what Ladybird expects of a Linux install inside the app's private storage, files/ladybird:
 *
 *   .lagom/      Ladybird's resources (fonts, themes, internal pages), unpacked from assets/lagom.zip
 *   libexec/     links to the helper processes. Android only lets an app run binaries it installed as native
 *                libraries, so the APK carries WebContent and the rest as lib<Name>.so.
 *   cacert.pem   the system's CA certificates, for RequestServer
 *
 * Ladybird looks for .lagom in $XDG_CONFIG_HOME (WebView::platform_init), and the helpers inherit the environment.
 */
object LadybirdRuntime {
    private val helpers = listOf("WebContent", "RequestServer", "ImageDecoder", "Compositor", "MediaServer", "WebWorker")

    private fun prefix(context: Context) = File(context.filesDir, "ladybird")

    fun setEnvironment(context: Context) {
        val prefix = prefix(context)
        prefix.mkdirs()
        Os.setenv("HOME", prefix.path, true)
        Os.setenv("XDG_CONFIG_HOME", prefix.path, true)
        val directories = listOf("XDG_DATA_HOME" to "data", "XDG_CACHE_HOME" to "cache", "XDG_RUNTIME_DIR" to "run", "TMPDIR" to "tmp")
        for ((name, directory) in directories) {
            val path = File(prefix, directory)
            path.mkdirs()
            Os.setenv(name, path.path, true)
        }
        // The helper processes are started with exec, outside the app's linker namespace; this is where any shared
        // library they need is.
        Os.setenv("LD_LIBRARY_PATH", context.applicationInfo.nativeLibraryDir, true)
        // Read by webby_init() (native/webby_ffi.cpp) as extra Ladybird arguments.
        Os.setenv("WEBBY_LADYBIRD_ARGS", "--certificate ${File(prefix, "cacert.pem").path}", true)
    }

    /** Unpacks and links everything; returns the prefix to hand to webby_init(). */
    fun prepare(context: Context): Map<String, String> {
        val prefix = prefix(context)
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val stamp = "${info.longVersionCode} ${info.lastUpdateTime}"
        val stampFile = File(prefix, ".unpacked")
        val resources = File(prefix, ".lagom")
        if (!resources.isDirectory || !stampFile.exists() || stampFile.readText() != stamp) {
            resources.deleteRecursively()
            unzip(context, "lagom.zip", resources)
            stampFile.writeText(stamp)
        }
        writeCertificates(File(prefix, "cacert.pem"))

        // The native library directory changes with every update, so the links are made afresh on each start.
        val libraryDirectory = File(context.applicationInfo.nativeLibraryDir)
        val libexec = File(prefix, "libexec")
        libexec.mkdirs()
        File(prefix, "bin").mkdirs()
        for (helper in helpers) {
            val link = File(libexec, helper)
            link.delete()
            val binary = File(libraryDirectory, "lib$helper.so")
            if (binary.exists()) Os.symlink(binary.path, link.path)
        }
        return mapOf("prefix" to prefix.path, "nativeLibraryDir" to libraryDirectory.path)
    }

    private fun unzip(context: Context, asset: String, destination: File) {
        val partial = File(destination.parentFile, destination.name + ".partial")
        partial.deleteRecursively()
        val root = partial.canonicalPath + File.separator
        ZipInputStream(context.assets.open(asset).buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val target = File(partial, entry.name)
                if (!target.canonicalPath.startsWith(root)) throw IOException("Bad path in $asset: ${entry.name}")
                if (entry.isDirectory) {
                    target.mkdirs()
                    continue
                }
                target.parentFile?.mkdirs()
                target.outputStream().use { zip.copyTo(it) }
            }
        }
        if (!partial.renameTo(destination)) throw IOException("Could not move $partial to $destination")
    }

    // Android keeps one PEM file per CA (with a text dump after it, which OpenSSL skips); curl wants one bundle.
    private fun writeCertificates(bundle: File) {
        val directory = listOf("/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts")
            .map(::File)
            .firstOrNull { it.isDirectory } ?: return
        val partial = File(bundle.path + ".partial")
        partial.outputStream().buffered().use { out ->
            directory.listFiles()?.sorted()?.forEach { file ->
                out.write(file.readBytes())
                out.write('\n'.code)
            }
        }
        if (!partial.renameTo(bundle)) throw IOException("Could not move $partial to $bundle")
    }
}
