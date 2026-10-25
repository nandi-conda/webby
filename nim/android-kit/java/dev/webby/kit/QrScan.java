package dev.webby.kit;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.util.Size;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.widget.FrameLayout;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.EnumMap;
import java.util.Map;

/**
 * A full-screen QR code scanner (Sync › I have a sync code › Scan QR code): the back camera's preview, with each
 * frame's brightness plane handed to ZXing until a QR code reads. Returns its text as the "text" extra; RESULT_CANCELED
 * when the user goes back or the camera can't be used.
 */
public class QrScan extends Activity {
    private static final String TAG = "webby";
    private static final int PERMISSION = 1;

    private TextureView preview;
    private HandlerThread thread;
    private Handler handler;
    private CameraDevice camera;
    private CameraCaptureSession session;
    private ImageReader reader;
    private Size size;
    private final QRCodeReader qr = new QRCodeReader();
    private final Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
    private volatile boolean done;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        hints.put(DecodeHintType.POSSIBLE_FORMATS, Arrays.asList(BarcodeFormat.QR_CODE));
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        preview = new TextureView(this);
        root.addView(preview, new FrameLayout.LayoutParams(-1, -1));
        TextView hint = new TextView(this);
        hint.setText("Point the camera at the QR code in webby's Sync panel on your other device");
        hint.setTextColor(Color.WHITE);
        hint.setBackgroundColor(0x99000000);
        hint.setGravity(Gravity.CENTER);
        int pad = Math.round(16 * getResources().getDisplayMetrics().density);
        hint.setPadding(pad, pad, pad, pad);
        root.addView(hint, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        setContentView(root);
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.CAMERA}, PERMISSION);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        if (requestCode != PERMISSION) return;
        if (results.length == 0 || results[0] != PackageManager.PERMISSION_GRANTED) {
            finish();
            return;
        }
        if (preview.isAvailable()) open();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (thread == null) {
            // kept until onDestroy: the camera reports its close on this thread after onPause
            thread = new HandlerThread("qr-scan");
            thread.start();
            handler = new Handler(thread.getLooper());
        }
        if (preview.isAvailable()) open();
        else preview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override public void onSurfaceTextureAvailable(SurfaceTexture t, int w, int h) { open(); }
            @Override public void onSurfaceTextureSizeChanged(SurfaceTexture t, int w, int h) { fit(); }
            @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture t) { return true; }
            @Override public void onSurfaceTextureUpdated(SurfaceTexture t) {}
        });
    }

    @Override
    protected void onPause() {
        close();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        if (thread != null) thread.quitSafely();
        super.onDestroy();
    }

    private void open() {
        if (camera != null || handler == null) return;
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return;
        CameraManager cm = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        try {
            String id = null;
            for (String c : cm.getCameraIdList()) {
                Integer facing = cm.getCameraCharacteristics(c).get(CameraCharacteristics.LENS_FACING);
                if (id == null || (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK)) id = c;
                if (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK) break;
            }
            if (id == null) {
                finish();
                return;
            }
            StreamConfigurationMap map = cm.getCameraCharacteristics(id).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            size = pick(map.getOutputSizes(ImageFormat.YUV_420_888));
            cm.openCamera(id, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice c) { camera = c; start(); }
                @Override public void onDisconnected(CameraDevice c) { c.close(); camera = null; }
                @Override public void onError(CameraDevice c, int error) {
                    Log.e(TAG, "qr scan: camera error " + error);
                    c.close();
                    camera = null;
                    runOnUiThread(QrScan.this::finish);
                }
            }, handler);
        } catch (Exception e) {
            Log.e(TAG, "qr scan: open", e);
            finish();
        }
    }

    /** About 1280x720: enough for a QR code across part of the frame, small enough to decode each frame quickly. */
    private static Size pick(Size[] sizes) {
        Size best = sizes[0];
        for (Size s : sizes) {
            long d = Math.abs((long) s.getWidth() * s.getHeight() - 1280L * 720);
            long b = Math.abs((long) best.getWidth() * best.getHeight() - 1280L * 720);
            if (s.getWidth() >= s.getHeight() && d < b) best = s;
        }
        return best;
    }

    private void start() {
        try {
            SurfaceTexture texture = preview.getSurfaceTexture();
            texture.setDefaultBufferSize(size.getWidth(), size.getHeight());
            runOnUiThread(this::fit);
            Surface surface = new Surface(texture);
            reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.YUV_420_888, 2);
            reader.setOnImageAvailableListener(this::frame, handler);
            CaptureRequest.Builder b = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            b.addTarget(surface);
            b.addTarget(reader.getSurface());
            b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
            CaptureRequest request = b.build();
            camera.createCaptureSession(Arrays.asList(surface, reader.getSurface()), new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession s) {
                    if (camera == null) return;
                    session = s;
                    try {
                        s.setRepeatingRequest(request, null, handler);
                    } catch (Exception e) {
                        Log.e(TAG, "qr scan: preview", e);
                    }
                }
                @Override public void onConfigureFailed(CameraCaptureSession s) {
                    Log.e(TAG, "qr scan: session failed");
                    runOnUiThread(QrScan.this::finish);
                }
            }, handler);
        } catch (Exception e) {
            Log.e(TAG, "qr scan: start", e);
            finish();
        }
    }

    /** Fills the view with the preview, cropping rather than stretching it (the activity stays portrait). */
    private void fit() {
        if (size == null) return;
        float vw = preview.getWidth(), vh = preview.getHeight();
        if (vw == 0 || vh == 0) return;
        float bw = size.getHeight(), bh = size.getWidth();   // the sensor's landscape frame, turned upright
        float scale = Math.max(vw / bw, vh / bh);
        Matrix m = new Matrix();
        m.setScale(bw * scale / vw, bh * scale / vh, vw / 2, vh / 2);
        preview.setTransform(m);
    }

    private void frame(ImageReader r) {
        Image image = r.acquireLatestImage();
        if (image == null) return;
        try {
            if (done) return;
            Image.Plane y = image.getPlanes()[0];
            ByteBuffer buf = y.getBuffer();
            int stride = y.getRowStride();
            int w = image.getWidth(), h = image.getHeight();
            byte[] data = new byte[stride * h];
            buf.get(data, 0, Math.min(buf.remaining(), data.length));
            PlanarYUVLuminanceSource source = new PlanarYUVLuminanceSource(data, stride, h, 0, 0, w, h, false);
            Result result;
            try {
                result = qr.decode(new BinaryBitmap(new HybridBinarizer(source)), hints);
            } catch (Exception notFound) {
                return;   // no code in this frame yet
            } finally {
                qr.reset();
            }
            done = true;
            String text = result.getText();
            runOnUiThread(() -> {
                setResult(RESULT_OK, new Intent().putExtra("text", text));
                finish();
            });
        } finally {
            image.close();
        }
    }

    private void close() {
        if (session != null) {
            session.close();
            session = null;
        }
        if (camera != null) {
            camera.close();
            camera = null;
        }
        if (reader != null) {
            reader.close();
            reader = null;
        }
    }
}
