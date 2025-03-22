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

// HTML editor helpers
// from Nash.html

// Helper: Place the caret at a given element and offset.
function setCaret(el, pos) {
    const selection = window.getSelection();
    const range = document.createRange();
    range.setStart(el, pos);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
}

function selectedNodes(range, nodeFilter) {
    const textNodes = [];
    if (range.commonAncestorContainer.nodeType === Node.TEXT_NODE) {
        textNodes.push(range.commonAncestorContainer);
    } else {
        const walker = document.createTreeWalker(
            range.commonAncestorContainer,
            nodeFilter,
            {
                acceptNode: function (node) {
                    return range.intersectsNode(node)
                        ? NodeFilter.FILTER_ACCEPT
                        : NodeFilter.FILTER_REJECT;
                }
            }
        );
        let node;
        while (node = walker.nextNode()) {
            textNodes.push(node);
        }
    }
    return textNodes
}

function hasAttr(node,tagName) {
    const ref = node.closest ? node.closest(tagName) : node.parentNode.closest(tagName);
    return ref !== null
}

function updateToolbar() {
    const sel = window.getSelection();
    const nodes = selectedNodes(sel.getRangeAt(0), NodeFilter.SHOW_ELEMENT);

    const textAttrs = ['STRONG','CODE', 'EM', 'U'];

    const state = {};
    for (let n of nodes) {
        for (let a of textAttrs) {
            if( hasAttr(n, a)) {
                state[a] ||= 1;
            }
        }
    }
    for (let a of textAttrs) {
        const el = document.getElementById(`btn-${a}`);
        if( state[a]) {
            htmx.addClass(el, 'toolbar-active');
        } else {
            htmx.removeClass(el, 'toolbar-active');
        }
    }
}

// Wrap only the selected portions of text nodes.
// If selection is entirely within one text node, process it directly.
function wrapRangeText(range, tagName, style, hook) {
    const textNodes = selectedNodes(range, NodeFilter.SHOW_TEXT);

    textNodes.forEach(function (textNode) {
        let start = 0, end = textNode.textContent.length;
        if (textNode === range.startContainer) {
            start = range.startOffset;
        }
        if (textNode === range.endContainer) {
            end = range.endOffset;
        }
        if (start >= end) return;

        const parent = textNode.parentNode;
        const wrapper = document.createElement(tagName);
        if (style) {
            wrapper.style.cssText = style;
        }
        if (hook) {
            hook(wrapper);
        }
        wrapper.textContent = textNode.textContent.substring(start, end);

        const frag = document.createDocumentFragment();
        const beforeText = textNode.textContent.substring(0, start);
        const afterText = textNode.textContent.substring(end);
        if (beforeText) {
            frag.appendChild(document.createTextNode(beforeText));
        }
        frag.appendChild(wrapper);
        if (afterText) {
            frag.appendChild(document.createTextNode(afterText));
        }
        parent.replaceChild(frag, textNode);
        const sel = document.getSelection();
        sel.selectAllChildren(wrapper);
    });
}

// Basic inline formatting: wraps the selection in the specified tag.
function applyFormat(tagName) {
    const selection = window.getSelection();
    if (!selection.rangeCount || selection.isCollapsed) return;
    const range = selection.getRangeAt(0);
    const editor = document.getElementById('usercontent');
    if (!editor.contains(range.commonAncestorContainer)) return;
    wrapRangeText(range, tagName);
    //selection.removeAllRanges();
    htmx.trigger(editor, 'input');
}

// Apply inline url
function applyURL() {
    const selection = window.getSelection();
    if (!selection.rangeCount || selection.isCollapsed) return;
    const range = selection.getRangeAt(0);
    const editor = document.getElementById('usercontent');
    if (!editor.contains(range.commonAncestorContainer)) return;
    const url = prompt("URL", range.toString());
    if (!url) return;
    wrapRangeText(range, 'a', null, function (element) {
        element.href = url;
    });
    //selection.removeAllRanges();
    htmx.trigger(editor, 'input');
}

// Convert the current block (direct child of #editor) to the chosen tag.
function changeBlock(tag) {
    const selection = window.getSelection();
    if (!selection.rangeCount) return;
    let node = selection.anchorNode;
    const editor = document.getElementById('usercontent');
    while (node && node.parentNode !== editor) {
        node = node.parentNode;
    }
    if (!node || node === editor) return;
    const newBlock = document.createElement(tag);
    while (node.firstChild) {
        if (
            node.firstChild.nodeType === Node.ELEMENT_NODE &&
            node.firstChild.matches('p') &&
            tag.match(/^H[1-6]$/)
        ) {
            let child = node.firstChild;
            while (child.firstChild) {
                newBlock.appendChild(child.firstChild);
            }
            node.removeChild(child);
        } else {
            newBlock.appendChild(node.firstChild);
        }
    }
    editor.replaceChild(newBlock, node);
    const range = document.createRange();
    range.selectNodeContents(newBlock);
    range.collapse(false);
    selection.removeAllRanges();
    selection.addRange(range);
    htmx.trigger(editor, 'input');
}
