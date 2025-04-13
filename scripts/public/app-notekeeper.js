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

const textAttrs = ['STRONG','CODE', 'EM', 'U', 'H1'];
function activeAttributes(range) {
    const nodes = selectedNodes(range, NodeFilter.SHOW_ELEMENT);

    const state = {};
    for (let n of nodes) {
        for (let a of textAttrs) {
            if( hasAttr(n, a)) {
                state[a] ||= 1;
            }
        }
    }
    return state
}

function updateToolbar() {
    const sel = window.getSelection();
    const state = activeAttributes( sel.getRangeAt(0));
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
    const toWrap = range.extractContents();
    const wrapper = document.createElement(tagName);
    if (style) {
        wrapper.style.cssText = style;
    }
    if (hook) {
        hook(wrapper);
    }
    wrapper.appendChild(toWrap);
    range.insertNode(wrapper);

    const sel = document.getSelection();
    sel.setBaseAndExtent(range.startContainer, range.startOffset, range.endContainer, range.endOffset);
}

function lastTextElement(node) {
    const r = new Range();
    r.selectNodeContents(node);
    return r.endContainer
}

// Mutator to remove all the tagName nodes from the tree
function removeTag(tree, filter) {
    const walker = document.createNodeIterator(
        tree,
        NodeFilter.SHOW_ELEMENT,
        {
            acceptNode: filter
        }
    );

    // Replace a node by its guts
    let node;
    while (node = walker.nextNode()) {
        const guts = node.childNodes;

        // replace the node by its contained children
        const frag = new DocumentFragment();
        while (node.childNodes.length) {
            frag.append(node.firstChild);
        };
        node.parentNode.replaceChild(frag, node);
    }
    return tree
}

// Remove a tag from the range, leaving only its contents in its place
function unwrapRangeText(range, tagName, hook) {

    // find upper-containing-tag
    let upperTag = range.commonAncestorContainer;
    if( upperTag.nodeType === Node.TEXT_NODE ) {
        upperTag = upperTag.parentNode;
    }
    upperTag = upperTag.closest(tagName) || upperTag;

    // If upperTag is the tag we want to eliminate
    // we need to include it in the selection and replace it
    const replaceContainer = upperTag.tagName === tagName;

    // allRange points to the first and last text node within upperTag
    const allRange = new Range();
    allRange.selectNodeContents(upperTag);

    const leftRange = new Range();
    if( replaceContainer ) {
        leftRange.setStartBefore(allRange.startContainer, 0);
    } else {
        leftRange.setStart(allRange.startContainer, 0);
    }
    leftRange.setEnd(range.startContainer, range.startOffset);

    const rightRange = new Range();
    rightRange.setStart(range.endContainer, range.endOffset);
    if( replaceContainer ) {
        rightRange.setEndAfter( allRange.endContainer, allRange.endOffset);
    } else {
        rightRange.setEnd( allRange.endContainer, allRange.endOffset);
    }

    const leftSide = leftRange.extractContents();
    const middle = range.extractContents();
    const rightSide = rightRange.extractContents();

    removeTag( middle.getRootNode(), (n) => { return n.tagName === tagName });

    // now replace the node(s) that we split up above with our new content
    // This empties the ranges, so we need to build selection afterwards
    // again
    const result = new DocumentFragment();
    result.appendChild(leftSide);
    const newSelection = new Range();
    newSelection.selectNodeContents(middle);
    const startEl = newSelection.startContainer.firstChild;
    const endEl = newSelection.endContainer.lastChild;
    result.appendChild(middle);
    result.appendChild(rightSide);

    if ( replaceContainer ) {
        upperTag.parentNode.replaceChild(result, upperTag);
    } else {
        allRange.insertNode(result);
    }

    // reconstruct the previous text selection. We use the text elements
    // that we saved above, as these persist their identity
    const sel = document.getSelection();
    sel.removeAllRanges();
    const newR = new Range();
    newR.setStartBefore(startEl);
    newR.setEndAfter(endEl);
    sel.addRange(newR);
}

// Basic inline formatting: wraps the selection in the specified tag.
function applyFormat(tagName, selection) {
    if (!selection.rangeCount || selection.isCollapsed) return;
    const range = selection.getRangeAt(0);
    const editor = document.getElementById('usercontent');
    if (!editor.contains(range.commonAncestorContainer)) return;
    wrapRangeText(range, tagName);
    htmx.trigger(editor, 'input');
}

// Basic inline formatting: removes the specified tag from the selection
function removeFormat(tagName, selection) {
    if (!selection.rangeCount || selection.isCollapsed) return;
    const range = selection.getRangeAt(0);
    const editor = document.getElementById('usercontent');
    if (!editor.contains(range.commonAncestorContainer)) return;
    unwrapRangeText(range, tagName);
    htmx.trigger(editor, 'input');
}

function toggleFormat(tagName) {
    const sel = window.getSelection();
    const state = activeAttributes( sel.getRangeAt(0));
    tagName = tagName.toUpperCase();

    if( state[ tagName ]) {
        removeFormat( tagName, sel );
    } else {
        applyFormat( tagName, sel );
    }
    updateToolbar();
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

/* Handle dark mode */
if ( window.matchMedia ) {
    function setTheme(theme) {
        document.documentElement.setAttribute('data-bs-theme', theme);
    }
    function updateTheme() {
        const theme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
        setTheme(theme);
    }
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        updateTheme()
    })
    updateTheme()
}
