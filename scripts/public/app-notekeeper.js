/* app-notekeeper.js */
"use strict";

let mediaRecorder;
let recordedChunks = [];

// Function to start the audio stream
async function startRecording() {
    const recordButton = document.getElementById('button-record');
    const stopButton = recordButton;
    const startCaption = recordButton.innerHTML;
    const input = document.getElementById('upload-audio');

    let stream = null;
    try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
        alert("Could not read audio recording device:"+e);
        return;
    }

    mediaRecorder = new MediaRecorder(stream);
    mediaRecorder.ondataavailable = event => {
        if (event.data.size > 0) {
            console.log("Bytes", event.data.size);
            recordedChunks.push(event.data);
        }
    };

    mediaRecorder.onstop = () => {
        const blob = new Blob(recordedChunks, { type: 'audio/ogg; codecs=opus' });
        const file = new File( [blob], 'audio-capture.ogg', {type: 'audio/ogg'} );
        const datTran = new ClipboardEvent('').clipboardData || new DataTransfer();
        datTran.items.add(file);  // Add the file to the DT object
        input.files = datTran.files; // overwrite the input file list with ours

        // We really want to do the sending in the background, later
        document.getElementById('do-upload').click();
        recordedChunks = [];
    };

    function toggleRecording() {
        if( ! recording ) {
            recordButton.innerHTML = "\u23F9"; // stop recording
            mediaRecorder.start();
            recording = true;

        } else {
            recordButton.innerHTML = startCaption;
            mediaRecorder.stop();
            recording = false;
        }
    }

    // Event listener to (re)start recording
    let recording = false;
    recordButton.addEventListener('click', toggleRecording );
    toggleRecording();
}
