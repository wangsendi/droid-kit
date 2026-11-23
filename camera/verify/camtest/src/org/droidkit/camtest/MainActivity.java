package org.droidkit.camtest;

import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.SurfaceTexture;
import android.hardware.Camera;
import android.os.Bundle;
import android.util.Log;
import android.webkit.ConsoleMessage;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;

import java.util.Arrays;
import java.util.List;

public class MainActivity extends Activity {
    private static final String TAG = "CAMTEST";
    private Camera camera;
    private WebView web;
    private int frames = 0;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (checkSelfPermission(android.Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{android.Manifest.permission.CAMERA}, 1);
        }
        startWebView();
    }

    private void startWebView() {
        web = new WebView(this);
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(true);
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                Log.i(TAG, "onPermissionRequest " + Arrays.toString(request.getResources()));
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        request.grant(request.getResources());
                    }
                });
            }

            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                Log.i(TAG, "console: " + m.message());
                return true;
            }
        });
        web.loadUrl("file:///android_asset/camtest.html");
    }

    private void startCamera1Probe() {
        try {
            int n = Camera.getNumberOfCameras();
            Log.i(TAG, "camera1 count=" + n);
            for (int i = 0; i < n; i++) {
                Camera.CameraInfo ci = new Camera.CameraInfo();
                Camera.getCameraInfo(i, ci);
                Log.i(TAG, "camera1 id=" + i + " facing=" + ci.facing
                        + " orientation=" + ci.orientation);
            }
            if (n == 0) return;
            camera = Camera.open(0);
            Camera.Parameters p = camera.getParameters();
            Camera.Size sz = p.getPreviewSize();
            Log.i(TAG, "camera1 opened preview=" + sz.width + "x" + sz.height
                    + " fmt=" + p.getPreviewFormat()
                    + " supported=" + p.getSupportedPreviewSizes());
            List<Integer> fmts = p.getSupportedPreviewFormats();
            Log.i(TAG, "camera1 supportedPreviewFormats=" + fmts);
            camera.setPreviewTexture(new SurfaceTexture(1));
            camera.startPreview();
            Log.i(TAG, "camera1 preview started");
        } catch (Throwable t) {
            Log.e(TAG, "camera1 probe failed", t);
        }
    }

    @Override
    protected void onDestroy() {
        if (camera != null) {
            try { camera.stopPreview(); camera.release(); } catch (Throwable ignored) {}
        }
        super.onDestroy();
    }
}
