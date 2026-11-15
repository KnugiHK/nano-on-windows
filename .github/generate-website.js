const fs = require('node:fs');
const path = require('node:path');
const { marked } = require('marked');
const markedAlert = require('marked-alert');

const rootDir = path.resolve(__dirname, '..');
const docsDir = path.join(rootDir, 'docs');
const version = (process.env.LATEST_TAG || 'latest').replace(/^v/, '');
const repository = 'KnugiHK/nano-on-windows';

function escapeHtml(value) {
    return value.replace(/[&<>"']/g, (character) => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
    })[character]);
}

function generateHtml(content) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Windows Binaries of GNU nano ${escapeHtml(version)}</title>
    <style>
        :root {
            color-scheme: light;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            color: #1a1a1a;
            background: #fff;
        }
        * { box-sizing: border-box; }
        body { margin: 0; line-height: 1.7; }
        .container { max-width: 860px; margin: 0 auto; padding: 48px 24px; }
        header { margin-bottom: 32px; padding-bottom: 28px; border-bottom: 1px solid #e5e7eb; }
        h1 { margin: 0 0 12px; font-size: 2.25rem; line-height: 1.2; }
        .subtitle, p, ul, ol { color: #59636e; }
        .button-group { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 24px; }
        .btn { display: inline-flex; align-items: center; justify-content: center; padding: 10px 18px; border: 0; border-radius: 6px; background: #1a1a1a; color: white; text-decoration: none; font: inherit; cursor: pointer; }
        .btn:hover { color: white; background: #333; }
        .btn-success { background: #10b981; }
        .btn-success:hover { background: #059669; }
        h2 { margin-top: 40px; }
        a { color: #2563eb; }
        code { padding: 2px 6px; border-radius: 4px; background: #f1f3f5; }
        pre { overflow-x: auto; padding: 18px; border: 1px solid #e5e7eb; border-radius: 8px; background: #f1f3f5; }
        pre code { padding: 0; }
        blockquote { margin: 24px 0; padding: 12px 18px; border-left: 4px solid #fbbf24; background: #fffbeb; }
        .markdown-alert { margin: 20px 0; padding: 14px 18px; border-left: 4px solid #0088cc; background: #f3f8fb; }
        .markdown-alert-title { margin-bottom: 8px; font-weight: 600; }
        table { display: block; overflow-x: auto; border-collapse: collapse; }
        th, td { padding: 8px 12px; border: 1px solid #e5e7eb; text-align: left; }
        img { max-width: 100%; height: auto; }
        footer { margin-top: 64px; padding-top: 24px; border-top: 1px solid #e5e7eb; text-align: center; font-size: .9rem; }
        .modal { display: none; position: fixed; inset: 0; z-index: 10; align-items: center; justify-content: center; padding: 20px; background: #0008; }
        .modal.active { display: flex; }
        .modal-content { width: min(100%, 480px); padding: 28px; border-radius: 12px; background: white; box-shadow: 0 20px 40px #0003; }
        .modal-content h2 { margin: 0 0 8px; }
        .option-buttons { display: flex; gap: 10px; margin: 18px 0 24px; }
        .option-btn { flex: 1; padding: 12px 8px; border: 2px solid #e5e7eb; border-radius: 6px; background: white; cursor: pointer; font: inherit; }
        .option-btn.selected { border-color: #2563eb; background: #2563eb; color: white; }
        .modal-footer { display: flex; justify-content: flex-end; gap: 10px; padding-top: 18px; border-top: 1px solid #e5e7eb; }
        .btn-secondary { background: #f1f3f5; color: #1a1a1a; }
        .btn-secondary:hover { background: #e5e7eb; color: #1a1a1a; }
        @media (max-width: 560px) {
            h1 { font-size: 1.8rem; }
            .container { padding: 32px 18px; }
            .option-buttons { flex-direction: column; }
            .modal-footer { flex-wrap: wrap; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Windows Binaries of GNU nano ${escapeHtml(version)}</h1>
            <p class="subtitle">A small, friendly text editor for use in a terminal.</p>
            <div class="button-group">
                <a class="btn" href="https://github.com/${repository}">View on GitHub</a>
                <button class="btn btn-success" id="downloadBtn">Download nano</button>
                <a class="btn" href="https://github.com/${repository}/releases/latest/download/datafiles.zip">Download syntax files</a>
            </div>
        </header>
        <main id="content">${content}</main>
        <footer>
            <p>Project maintained by <a href="https://knugi.com/">KnugiHK</a></p>
            <p>Licensed under <a href="https://github.com/${repository}/blob/main/LICENSE">GPLv3+</a></p>
            <p><small>Last updated: ${new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })}</small></p>
        </footer>
    </div>
    <div id="downloadModal" class="modal" role="dialog" aria-modal="true" aria-labelledby="modalTitle">
        <div class="modal-content">
            <h2 id="modalTitle">Download nano ${escapeHtml(version)}</h2>
            <p>Select your preferred architecture.</p>
            <div class="option-buttons">
                <button class="option-btn selected" data-arch="x64">x64 (64-bit)</button>
                <button class="option-btn" data-arch="x86">x86 (32-bit)</button>
                <button class="option-btn" data-arch="arm64">ARM64</button>
            </div>
            <div class="modal-footer">
                <button class="btn btn-secondary" id="cancelBtn">Cancel</button>
                <button class="btn btn-success" id="confirmDownloadBtn">Download</button>
            </div>
        </div>
    </div>
    <script>
        const modal = document.getElementById('downloadModal');
        const optionButtons = document.querySelectorAll('.option-btn');
        let selectedArch = 'x64';

        function closeModal() {
            modal.classList.remove('active');
            document.body.style.overflow = '';
        }

        document.getElementById('downloadBtn').addEventListener('click', () => {
            modal.classList.add('active');
            document.body.style.overflow = 'hidden';
        });
        document.getElementById('cancelBtn').addEventListener('click', closeModal);
        modal.addEventListener('click', (event) => {
            if (event.target === modal) closeModal();
        });
        document.addEventListener('keydown', (event) => {
            if (event.key === 'Escape' && modal.classList.contains('active')) closeModal();
        });
        optionButtons.forEach((button) => {
            button.addEventListener('click', () => {
                optionButtons.forEach((option) => option.classList.remove('selected'));
                button.classList.add('selected');
                selectedArch = button.dataset.arch;
            });
        });
        document.getElementById('confirmDownloadBtn').addEventListener('click', () => {
            const fileName = 'nano-' + selectedArch + '.exe';
            const link = document.createElement('a');
            link.href = 'https://github.com/${repository}/releases/latest/download/' + fileName;
            link.download = fileName;
            document.body.appendChild(link);
            link.click();
            link.remove();
            closeModal();
        });
    </script>
</body>
</html>`;
}

function generateSite() {
    const readmePath = path.join(rootDir, 'README.md');
    const readme = fs.readFileSync(readmePath, 'utf8');
    const markdown = readme.replace(/^#\s+.+(?:\r?\n|$)/m, '');
    const content = marked.use(markedAlert()).parse(markdown, {
        gfm: true,
        breaks: true
    });

    fs.mkdirSync(docsDir, { recursive: true });
    fs.writeFileSync(path.join(docsDir, 'index.html'), generateHtml(content));
    console.log('Website generated: docs/index.html');
}

generateSite();
