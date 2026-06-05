package com.videostream.video_stream

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import java.io.ByteArrayOutputStream

class DualCameraService(private val context: Context) {
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var handler: Handler? = null
    private var handlerThread: HandlerThread? = null
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val TAG = "DualCameraService"

    var onFrameCallback: ((ByteArray) -> Unit)? = null
    var onCameraError: (() -> Unit)? = null
    private var isRunning = false
    private var useFrontCamera = true
    private var quality = 50 // JPEG quality

    fun start(useFront: Boolean) {
        android.util.Log.d(TAG, "start() called, useFront=$useFront")
        if (isRunning) stop()
        useFrontCamera = useFront
        startBackgroundThread()
        openCamera()
        isRunning = true
    }

    fun stop() {
        isRunning = false
        captureSession?.close()
        captureSession = null
        cameraDevice?.close()
        cameraDevice = null
        imageReader?.close()
        imageReader = null
        stopBackgroundThread()
    }

    private fun startBackgroundThread() {
        handlerThread = HandlerThread("DualCamera").also { it.start() }
        handler = Handler(handlerThread!!.looper)
    }

    private fun stopBackgroundThread() {
        handlerThread?.quitSafely()
        try { handlerThread?.join() } catch (_: Exception) {}
        handlerThread = null
        handler = null
    }

    private fun getCameraId(): String? {
        val facing = if (useFrontCamera) CameraCharacteristics.LENS_FACING_FRONT
                     else CameraCharacteristics.LENS_FACING_BACK
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == facing) return id
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun openCamera() {
        val cameraId = getCameraId()
        android.util.Log.d(TAG, "openCamera() cameraId=$cameraId")
        if (cameraId == null) return
        try {
            imageReader = ImageReader.newInstance(320, 240, ImageFormat.YUV_420_888, 2)
            imageReader?.setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val jpeg = yuvToJpeg(image)
                    android.util.Log.d(TAG, "Frame captured, size=${jpeg?.size}")
                    if (jpeg != null) onFrameCallback?.invoke(jpeg)
                } finally {
                    image.close()
                }
            }, handler)

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    android.util.Log.d(TAG, "Camera opened successfully")
                    cameraDevice = camera
                    createCaptureSession()
                }
                override fun onDisconnected(camera: CameraDevice) {
                    android.util.Log.d(TAG, "Camera disconnected")
                    camera.close()
                    onCameraError?.invoke()
                }
                override fun onError(camera: CameraDevice, error: Int) {
                    android.util.Log.e(TAG, "Camera error: $error")
                    camera.close()
                    onCameraError?.invoke()
                }
            }, handler)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "openCamera exception: ${e.message}")
            e.printStackTrace()
        }
    }

    private fun createCaptureSession() {
        val surface = imageReader?.surface ?: return
        try {
            val builder = cameraDevice?.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            builder?.addTarget(surface)
            builder?.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(10, 15))

            cameraDevice?.createCaptureSession(listOf(surface), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    builder?.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                    session.setRepeatingRequest(builder!!.build(), null, handler)
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {}
            }, handler)
        } catch (e: Exception) { e.printStackTrace() }
    }

    private fun yuvToJpeg(image: android.media.Image): ByteArray? {
        val yBuffer = image.planes[0].buffer
        val uBuffer = image.planes[1].buffer
        val vBuffer = image.planes[2].buffer
        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()
        val nv21 = ByteArray(ySize + uSize + vSize)
        yBuffer.get(nv21, 0, ySize)
        vBuffer.get(nv21, ySize, vSize)
        uBuffer.get(nv21, ySize + vSize, uSize)

        val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), quality, out)
        return out.toByteArray()
    }
}
