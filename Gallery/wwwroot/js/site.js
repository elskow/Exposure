// Please see documentation at https://learn.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

/**
 * Enhanced Lazy Loading with Intersection Observer
 * - Loads images only when they enter viewport (with margin)
 * - Smooth fade-in transition
 * - Fallback support for older browsers
 */
(function() {
    'use strict';

    const lazyImageObserver = new IntersectionObserver((entries, observer) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                const img = entry.target;
                const src = img.dataset.src;
                const fallbackSrc = img.dataset.fallback;

                if (src) {
                    // Create a new image to preload
                    const preloader = new Image();
                    
                    preloader.onload = function() {
                        img.src = src;
                        img.classList.add('lazy-loaded');
                        img.classList.remove('lazy-loading');
                    };

                    preloader.onerror = function() {
                        if (fallbackSrc) {
                            img.src = fallbackSrc;
                        }
                        img.classList.add('lazy-loaded');
                        img.classList.remove('lazy-loading');
                    };

                    preloader.src = src;
                }

                observer.unobserve(img);
            }
        });
    }, {
        // Start loading when image is 200px from viewport
        rootMargin: '200px 0px',
        threshold: 0.01
    });

    // Initialize lazy loading
    function initLazyLoading() {
        const lazyImages = document.querySelectorAll('img[data-src]');
        
        if ('IntersectionObserver' in window) {
            lazyImages.forEach(img => {
                img.classList.add('lazy-loading');
                lazyImageObserver.observe(img);
            });
        } else {
            // Fallback for browsers without IntersectionObserver
            lazyImages.forEach(img => {
                img.src = img.dataset.src;
            });
        }
    }

    // Run on DOM ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initLazyLoading);
    } else {
        initLazyLoading();
    }

    // Re-initialize on dynamic content (for SPA-like behavior)
    window.initLazyLoading = initLazyLoading;
})();
