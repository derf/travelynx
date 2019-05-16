var validThemes = ['dark.min', 'light.min'];
var currentTheme = localStorage.getItem('theme');
if (!validThemes.includes(currentTheme)) {
    currentTheme = window.matchMedia('(prefers-color-scheme: dark').matches ? 'dark.min' : 'light.min';
}
addStyleSheet(currentTheme, 'theme');

function toggleTheme() {
    currentTheme = currentTheme === 'dark.min' ? 'light.min' : 'dark.min';
    localStorage.setItem('theme', currentTheme);
    addStyleSheet(currentTheme, 'theme');
}
