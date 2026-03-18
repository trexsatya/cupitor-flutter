(function() {
  function getWords(text) {
    if (typeof Intl !== 'undefined' && Intl.Segmenter) {
      const segmentor = new Intl.Segmenter([], {granularity: 'word'});
      return Array.from(segmentor.segment(text), ({segment}) => segment);
    } else {
      return text.split(/(\s+|[.,!?;:"'()\-])/g).filter(Boolean);
    }
  }

  function wrapWordsInNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      const parent = node.parentNode;
      if (parent && parent.closest('a')) return;
      const words = getWords(node.textContent);
      const frag = document.createDocumentFragment();
      words.forEach(word => {
        if (word.trim().length <= 2) {
          frag.appendChild(document.createTextNode(word));
        } else {
          const span = document.createElement('span');
          span.className = 'clickable-word';
          span.dataset.word = word;
          span.textContent = word;
          frag.appendChild(span);
        }
      });
      parent.replaceChild(frag, node);
    } else if (node.nodeType === Node.ELEMENT_NODE && node.tagName.toLowerCase() !== 'a') {
      Array.from(node.childNodes).forEach(wrapWordsInNode);
    }
  }

  function main() {
    setTimeout(() => {
      console.log("Starting to wrap words in document body");
      wrapWordsInNode(document.body);
      console.log("Finished wrapping words in document body");
    }, 2000);

    if (!window.myCustomerListenerAttached) {
      document.addEventListener('click', (e) => {
        let t = e.target.closest('.clickable-word');
        if (t) {
          try {
             CaptionHandler.postMessage(t.dataset.word);
          } catch(e) {}
        }
      });
      window.myCustomerListenerAttached = true;
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
