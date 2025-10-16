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
    if( !sel.rangeCount ) return;
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
    if (!sel.rangeCount || sel.isCollapsed) return;
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

function hotkeyHandlerDocuments( evt ) {
    evt = evt || window.event;

    if( evt.ctrlKey ) return;
    if( evt.altKey ) return;
    if( evt.metaKey ) return;

    // Maybe convert to dispatch table?
    if (evt.key == 's' || evt.key == "/") {
        if ((evt.target instanceof HTMLTextAreaElement) || (evt.target instanceof HTMLInputElement)) return;
        let searchBox = htmx.find('#text-filter');
        if( searchBox ) {
            searchBox.focus();
            evt.stopPropagation();
            return false;
        }
    } else if (evt.key == 'n' || evt.key == "c") {
        if ((evt.target instanceof HTMLTextAreaElement) || (evt.target instanceof HTMLInputElement)) return;
        let newNote = htmx.find('#btn-new-note');
        if( newNote ) {
            newNote.click();
            evt.stopPropagation();
            return false;
        }
    } else if (evt.key == 't') {
        if ((evt.target instanceof HTMLTextAreaElement) || (evt.target instanceof HTMLInputElement)) return;
        htmx.find("#btn-new-from-template").click()
    } else if (evt.key == 'Escape') {
        // hide search/filter bar?!
    } else {
        // console.log( evt.key )
    };
}

function hotkeyHandlerNote( evt ) {
    evt = evt || window.event;

    if (evt.ctrlKey && evt.key == '1') {
        let searchBox = htmx.find('#btn-switch-editor-md');
        if( searchBox ) {
            searchBox.click();
            evt.stopPropagation();
            return false;
        };
    } else if (evt.ctrlKey && evt.key == '2') {
        let searchBox = htmx.find('#btn-switch-editor-html');
        if( searchBox ) {
            searchBox.click();
            evt.stopPropagation();
            return false;
        }
    };
    if( evt.altKey ) return;
    if( evt.metaKey ) return;

    // Return to list on Escape is handled by the inline JS, because it knows
    // about a fragment that we want to jump to

    // Maybe convert to dispatch table?
    if (0) {
    } else {
        // console.log( evt.key )
    };
}


function dropHandler( formName, e ) {
    // do a manual upload via ajax, since submitting the form itself
    // does not work...
    const files = e.dataTransfer.files;
    const form = htmx.find( formName );
    if(! form) {
        console.log(`Internal error: Upload form ${formName} not found.`);
    }

    const formData = new FormData();
    const filesValues = [];
    for (let file of files) {
        formData.append( "file", file, file.name );
    }
    return htmx.ajax('POST',
        form.getAttribute('action'),
        {
            values: {
                "file" : formData.getAll('file'),
            },
            headers: {
                "content-encoding":"multipart/form-data"
            },
            source: form,
        }
    )
}

function scrollToFragment() {
    let fr = window.location.hash;
    if( fr ) {
        // fr already contains a leading "#"
        const target = htmx.find(fr);
        console.log(target);
        if(target)target.scrollIntoView({
            behavior: "instant",
            block: "center",
        });
    }
}

function getUserContent() {
    const el = htmx.find('#usercontent');

    const selectionStartMarker = "\u2039";
    const selectionEndMarker = "\u203A";

    if( el ) {
        let sel;
        // We assume we always have text nodes in the selection, and not
        // other complete nodes like <img>...
        const undo = [];
        const innerHTML = el.innerHTML;

        // Find the user selection, if any
        let orgS,orgR;
        if( sel = document.getSelection()) {
            const r = sel.getRangeAt(0);
            // copy selection range information so we can restore it after modifying stuff
            orgR = { startContainer: r.startContainer,
                     startOffset: r.startOffset,
                     endContainer: r.endContainer,
                     endOffset: r.endOffset };
            orgS = { ...sel };

            // This needs a fix - we might need to add a text node right
            // before/after the element starts, for example |<img>
            // If start and end are in the same container, edit it directly:
            // XXX Check if the container is a text node!
            if( sel.anchorNode === sel.focusNode ) {
                // Swap direction if it is not "forward"
                const text = sel.anchorNode.textContent;
                sel.anchorNode.textContent = text.slice(0,sel.anchorOffset)
                                                +selectionStartMarker
                                                +text.slice(sel.anchorOffset, sel.focusOffset)
                                                +selectionEndMarker
                                                +text.slice(sel.focusOffset)
                                                ;
                undo.unshift( [sel.anchorNode,text]);
            } else {
                const sText = sel.anchorNode.textContent;
                const eText = sel.focusNode.textContent;
                sel.anchorNode.textContent = sText.slice(0,sel.anchorOffset)
                                                +selectionStartMarker
                                                +sText.slice(sel,anchorOffset);
                sel.focusNode.textContent = eText.slice(0,sel.focusOffset)
                                              +selectionEndMarker
                                              +eText.slice(sel.focusOffset);
                undo.unshift( [sel.anchorNode,sText]);
                undo.unshift( [sel.focusNode,eText]);
            }
        }

        const markerInnerHTML = el.innerHTML;
        // Convert our markers to positions in the string
        let selectionStart = markerInnerHTML.indexOf(selectionStartMarker);
        let selectionEnd = markerInnerHTML.indexOf(selectionEndMarker);

        if( selectionEnd > selectionStart ) selectionEnd -= selectionStartMarker.length;
        if( selectionStart > selectionEnd ) selectionStart -= selectionStartMarker.length;

        // Remove start/end unicode markers from the browser HTML again
        for (let u of undo) {
            let [e,t] = u;
            e.textContent = t; // boom
        }
        //      restore original selection
        if( orgR ) {
            sel.removeAllRanges();
            const newR = document.createRange();
            console.log(orgR);
            newR.setStart(orgR.startContainer, orgR.startOffset);
            newR.setEnd(orgR.endContainer, orgR.endOffset);
            sel.addRange(newR);
        }
        return { "body-html" : innerHTML,
                 "focus-position": undefined,
                 "selection-start": selectionStart,
                 "selection-end": selectionEnd,
               }
    } else {
        return { };
    }
}

function getUserCaret() {
    const c = getUserContent();
    let res;
    if( c ) {
        res = {
            "selection-start":c["selection-start"],
            "selection-end":c["selection-end"],
        }
    }
    return res
}

function getUserSelection() {
    // If we are in the textarea, use textarea.selectionStart, textarea.selectionEnd
    // and textarea.selectionDirection
    // otherwise use document.getSelection()

    // When clicking on an editor-switch button, we lost the active element...
    const active = document.activeElement;
    let u = htmx.find('#usercontent');
    let t = htmx.find('#note-textarea');

    if( u && u.contains(active)) {
        // Ugh, shoudl check if we actually have a selection?
        const s = document.getSelection().getRangeAt(0);
        return {

        }

    } else if( t && t.contains(active)) {
        return {
            start: t.selectionStart,
            end: t.selectionEnd,
            dir: t.selectionDirection
        }
    } else {
        return {}
    }
}

/* Called for every page/fragment loaded by HTMX */
// Set up all listeners
let appInitialized;
function setupApp() {
    // Setup for each page
    htmx.on("htmx:afterSettle", scrollToFragment);

    const singleNote = htmx.find('.note-container');
    const noteList   = htmx.find('#documents');

    if( singleNote ) {
        document.onkeydown = hotkeyHandlerNote;

        let uploadArea = htmx.find('.note-container');
        if( uploadArea ) {
            uploadArea.addEventListener("drop", (e) => dropHandler("#form-attach-file",e));

            // stop weird behaviour if dropping the file elsewhere:
            window.addEventListener("dragover", (e) => {
                e.preventDefault();
            });
            window.addEventListener("drop", (e) => {
                e.preventDefault();
            });
        }

        const checkboxes = singleNote.querySelectorAll( '.note-container input[type=checkbox]' );
        checkboxes.forEach( (c) =>  {
            c.addEventListener( 'change', function(e) {
                const el = e.target;

                if (el.checked) {
                    el.setAttribute("checked","checked");
                } else {
                    el.removeAttribute("checked","checked");
                }

                });
            }
        );

        // Restore user selection and caret position
        const a = htmx.find('#note-textarea');
        if( a && a.dataset && a.dataset.selectionStart ) {
            let start = a.dataset.selectionStart;
            let end = a.dataset.selectionEnd;
            let direction = 'forward';
            if( end < start ) {
                direction = 'backward';
                [start,end] = [end,start];
            }
            a.setSelectionRange(start,end,direction);
            a.removeAttribute('data-selection-start');
            a.removeAttribute('data-selection-end');
        }
    };

    if( noteList ) {
        document.onkeydown = hotkeyHandlerDocuments;

        let globalUploadArea = htmx.find('.documents');
        if( globalUploadArea ) {
            globalUploadArea.addEventListener("drop", (e) => dropHandler("#form-new-note",e));

            // stop weird behaviour if dropping the file elsewhere:
            window.addEventListener("dragover", (e) => {
                e.preventDefault();
            });
            window.addEventListener("drop", (e) => {
                e.preventDefault();
            });
        }
    }

    if( appInitialized ) { return; };
    appInitialized = true;

    // Global only-once setup
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

    // Hide all nodes that have the 'nojs' class
    const sheet = window.document.styleSheets[1];
    let removeRules = [];
    let index = 0;
    for (let r of sheet.cssRules) {
        if( r.selectorText === '.nojs' ) {
            r.style.display = 'none';

        } else if( r.selectorText === '.jsonly' ) {
            // Reverse order so we can delete without shifting the array indices
            removeRules.unshift( index );
        }
        index++;
    };

    for (let i of removeRules ) {
        sheet.removeRule(i);
    }
}
htmx.onLoad(setupApp);
// per-page setup
//htmx.onLoad(setupPage);
