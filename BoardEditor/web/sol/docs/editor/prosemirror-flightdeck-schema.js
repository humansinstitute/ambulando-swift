import { FlightDeckWikiLink } from './wiki-extension.js';
import StarterKit from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import Placeholder from '@tiptap/extension-placeholder';
import { Table } from '@tiptap/extension-table';
import TableRow from '@tiptap/extension-table-row';
import TableCell from '@tiptap/extension-table-cell';
import TableHeader from '@tiptap/extension-table-header';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import Image from '@tiptap/extension-image';
import { Extension, Mark, Node, mergeAttributes } from '@tiptap/core';
import { Plugin } from '@tiptap/pm/state';
import { createFlightDeckBlockId } from './prosemirror-constants.js';

export {
  FLIGHTDECK_PROSEMIRROR_CONTENT_FORMAT,
  PROSEMIRROR_JSON_FORMAT,
  PROSEMIRROR_JSON_VERSION,
  createFlightDeckBlockId,
} from './prosemirror-constants.js';

const TOP_LEVEL_BLOCK_TYPES = new Set([
  'paragraph',
  'heading',
  'bulletList',
  'orderedList',
  'taskList',
  'blockquote',
  'codeBlock',
  'horizontalRule',
  'table',
]);

function shouldCarryBlockId(typeName) {
  return TOP_LEVEL_BLOCK_TYPES.has(String(typeName || ''));
}

export const FlightDeckBlockIdExtension = Extension.create({
  name: 'fdBlockId',
  addGlobalAttributes() {
    return [
      {
        types: [...TOP_LEVEL_BLOCK_TYPES],
        attributes: {
          fdBlockId: {
            default: null,
            parseHTML: (element) => element.getAttribute('data-fd-block-id'),
            renderHTML: (attributes) => (
              attributes.fdBlockId ? { 'data-fd-block-id': attributes.fdBlockId } : {}
            ),
          },
        },
      },
    ];
  },
  addProseMirrorPlugins() {
    return [
      new Plugin({
        appendTransaction: (_transactions, _oldState, newState) => {
          let tr = null;
          const seen = new Set();
          newState.doc.descendants((node, pos, parent) => {
            if (!shouldCarryBlockId(node.type.name)) return;
            const id = node.attrs.fdBlockId;
            if (id && !seen.has(id)) {
              seen.add(id);
              return;
            }
            if (!id && parent !== newState.doc) return;
            // Keep the first identity so existing comment anchors remain valid.
            // Copies need fresh top-level IDs; nested duplicates have no block.
            const nextId = parent === newState.doc ? createFlightDeckBlockId() : null;
            if (nextId) seen.add(nextId);
            tr = tr || newState.tr;
            tr.setNodeMarkup(pos, undefined, { ...node.attrs, fdBlockId: nextId });
          });
          return tr;
        },
      }),
    ];
  },
});

export const FlightDeckMention = Mark.create({
  name: 'fdMention',
  inclusive: false,
  addAttributes() {
    return {
      mentionType: { default: null },
      mentionId: { default: null },
      label: { default: null },
    };
  },
  parseHTML() {
    return [{ tag: 'span[data-fd-mention-id]' }];
  },
  renderHTML({ HTMLAttributes }) {
    return ['span', mergeAttributes(HTMLAttributes, {
      'data-fd-mention-type': HTMLAttributes.mentionType,
      'data-fd-mention-id': HTMLAttributes.mentionId,
      class: 'fd-mention mention-link',
      'data-mention-type': HTMLAttributes.mentionType,
      'data-mention-id': HTMLAttributes.mentionId,
      role: 'link',
      tabindex: '0',
    }), 0];
  },
});

export const FlightDeckStorageFile = Node.create({
  name: 'fdStorageFile',
  group: 'block',
  atom: true,
  draggable: true,
  addAttributes() {
    return {
      src: { default: null },
      title: { default: null },
      label: { default: null },
    };
  },
  parseHTML() {
    return [{ tag: 'div[data-fd-storage-file]' }];
  },
  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, {
      'data-fd-storage-file': HTMLAttributes.src,
      class: 'fd-storage-file-card',
    }), HTMLAttributes.label || HTMLAttributes.title || HTMLAttributes.src || 'File'];
  },
});

export const FlightDeckStorageImage = Image.extend({
  name: 'fdStorageImage',
  addAttributes() {
    return {
      ...this.parent?.(),
      objectId: { default: null },
      title: { default: null },
    };
  },
  renderHTML({ HTMLAttributes }) {
    const objectId = String(HTMLAttributes.objectId || '').trim();
    const isStorageImage = Boolean(objectId) || String(HTMLAttributes.src || '').startsWith('storage://');
    return ['img', mergeAttributes(HTMLAttributes, {
      src: isStorageImage ? null : HTMLAttributes.src,
      'data-fd-storage-object-id': objectId || null,
      'data-storage-object-id': objectId || null,
      class: isStorageImage ? 'md-storage-image md-storage-image-pending' : 'md-storage-image',
    })];
  },
});

export const FlightDeckUploadPlaceholder = Node.create({
  name: 'fdUploadPlaceholder',
  group: 'block',
  atom: true,
  selectable: false,
  addAttributes() {
    return {
      uploadId: { default: null },
      label: { default: 'Uploading image...' },
    };
  },
  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, {
      'data-doc-rich-upload-id': HTMLAttributes.uploadId,
      class: 'doc-rich-upload-placeholder',
    }), HTMLAttributes.label || 'Uploading image...'];
  },
});

export function createFlightDeckTiptapExtensions(options = {}) {
  return [
    StarterKit.configure({
      link: false,
      ...(options.editable === false ? { trailingNode: false, undoRedo: false, dropcursor: false } : {}),
      heading: { levels: [1, 2, 3, 4] },
    }),
    Link.configure({
      openOnClick: false,
      autolink: true,
      linkOnPaste: true,
      isAllowedUri: (url, context) => /^mention:[a-z]+:[^\s]+$/i.test(url) || context.defaultValidate(url),
    }).extend({
      renderHTML({ HTMLAttributes }) {
        const reference = String(HTMLAttributes.href || '').match(/^mention:([^:]+):(.+)$/);
        if (!reference) return this.parent({ HTMLAttributes });
        return ['a', mergeAttributes(this.options.HTMLAttributes, HTMLAttributes, {
          href: '#', class: 'mention-link',
          'data-mention-type': reference[1], 'data-mention-id': reference[2],
        }), 0];
      },
    }),
    ...(options.editable === false ? [] : [Placeholder.configure({
      placeholder: options.placeholder || 'Start writing...',
    })]),
    Table.configure({ resizable: options.editable !== false }),
    TableRow,
    TableHeader,
    TableCell,
    TaskList,
    TaskItem.configure({ nested: true }),
    FlightDeckStorageImage,
    FlightDeckStorageFile,
    FlightDeckUploadPlaceholder,
    FlightDeckMention,
    FlightDeckWikiLink,
    FlightDeckBlockIdExtension,
  ];
}
