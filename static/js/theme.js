// Theme toggle functionality
(function() {
    const themeToggle = document.getElementById('theme-toggle');

    if (!themeToggle) return;

    function setTheme(theme) {
        document.documentElement.setAttribute('data-theme', theme);
        localStorage.setItem('theme', theme);

        // Update highlight.js theme
        const hljsDark = document.getElementById('hljs-dark');
        const hljsLight = document.getElementById('hljs-light');

        if (hljsDark && hljsLight) {
            if (theme === 'light') {
                hljsDark.disabled = true;
                hljsLight.disabled = false;
            } else {
                hljsDark.disabled = false;
                hljsLight.disabled = true;
            }
        }
    }

    function toggleTheme() {
        const currentTheme = document.documentElement.getAttribute('data-theme');
        const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
        setTheme(newTheme);
    }

    themeToggle.addEventListener('click', toggleTheme);

    // Initialize theme from localStorage
    const savedTheme = localStorage.getItem('theme');
    if (savedTheme) {
        setTheme(savedTheme);
    }
})();
