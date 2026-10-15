package dev.webby.kit;

import android.os.Process;
import java.io.File;

/**
 * An incognito window: the same front end started with --incognito, in a process of its own (":incognito" in the
 * manifest) and its own task in Recents, as the desktop runs `webby --incognito`. Its throwaway Ladybird profile
 * (XDG_RUNTIME_DIR/webby-incognito-<pid>) goes, and the process with it, when the window is closed.
 */
public class IncognitoHost extends WebbyHost {
    @Override
    protected String args() {
        return "--incognito";
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (!isFinishing()) return;
        String run = System.getenv("XDG_RUNTIME_DIR");
        if (run != null) deleteRecursively(new File(run, "webby-incognito-" + Process.myPid()));
        Process.killProcess(Process.myPid());
    }

    private static void deleteRecursively(File f) {
        File[] kids = f.isDirectory() && !java.nio.file.Files.isSymbolicLink(f.toPath()) ? f.listFiles() : null;
        if (kids != null) for (File k : kids) deleteRecursively(k);
        f.delete();
    }
}
