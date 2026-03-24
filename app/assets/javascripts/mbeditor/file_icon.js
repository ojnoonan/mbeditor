var MbeditorFileIcon = (function () {
  function getFileIcon(name) {
    var value = String(name || '');
    var lower = value.toLowerCase();
    var parts = lower.split('.');
    var ext = parts.length > 1 ? parts.pop() : '';

    if (lower === 'gemfile' || ext === 'gemspec' || ext === 'lock') return 'fas fa-gem ruby-icon';
    if (ext === 'rb' || ext === 'rake' || lower === 'rakefile') return 'far fa-gem ruby-icon';
    if (ext === 'jsx' || lower.endsWith('.js.jsx')) return 'fas fa-atom react-icon';
    if (ext === 'js' || ext === 'mjs' || ext === 'cjs') return 'fa-brands fa-js js-icon';
    if (ext === 'ts' || ext === 'tsx') return 'fas fa-code typescript-icon';
    if (ext === 'html' || ext === 'htm') return 'fa-brands fa-html5 html-icon';
    if (ext === 'erb') return 'fa-brands fa-html5 erb-icon';
    if (ext === 'css' || ext === 'scss' || ext === 'sass') return 'fa-brands fa-css3-alt css-icon';
    if (['png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp', 'bmp', 'avif'].includes(ext)) return 'far fa-file-image image-icon';
    if (ext === 'json') return 'fas fa-code json-icon';
    if (ext === 'md' || ext === 'txt') return 'fas fa-file-alt md-icon';
    if (ext === 'yml' || ext === 'yaml') return 'fas fa-cogs yml-icon';
    if (ext === 'sh' || ext === 'bash' || ext === 'zsh') return 'fas fa-terminal shell-icon';
    if (ext === 'pdf') return 'far fa-file-pdf pdf-icon';

    return 'far fa-file-code';
  }

  return { getFileIcon: getFileIcon };
})();

window.MbeditorFileIcon = MbeditorFileIcon;
window.getFileIcon = window.getFileIcon || MbeditorFileIcon.getFileIcon;