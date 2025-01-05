/* app-notekeeper.js */
"use strict";

let mediaRecorder;
let recordedChunks = [];

// Function to start the audio stream
async function startRecording() {
    const audio = document.getElementById('audio');
    const recordButton = document.getElementById('record');
    const stopButton = document.getElementById('stop');

    let stream = null;
    try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
        alert("Could not read audio recording device:"+e);
        return;
    }
    audio.srcObject = stream;

    mediaRecorder = new MediaRecorder(stream);
    mediaRecorder.ondataavailable = event => {
        if (event.data.size > 0) {
            console.log("Bytes", event.data.size);
            recordedChunks.push(event.data);
        }
    };

    mediaRecorder.onstop = () => {
        const blob = new Blob(recordedChunks, { type: 'audio/ogg; codecs=opus' });
        console.log(blob);
        const input = document.getElementById('upload-audio');
        const file = new File( [blob], 'audio-capture.ogg', {type: 'audio/ogg'} );
        const datTran = new ClipboardEvent('').clipboardData || new DataTransfer();
        datTran.items.add(file);  // Add the file to the DT object
        input.files = datTran.files; // overwrite the input file list with ours
        document.getElementById('do-upload').click();
        recordedChunks = [];
    };

    // Event listener to start recording
    recordButton.addEventListener('click', () => {
        mediaRecorder.start();
    });

    // Event listener to stop recording
    stopButton.addEventListener('click', () => {
        mediaRecorder.stop();
    });

    console.log(recordButton);
}

