# Why Glacier sometimes shows a gray box instead of a link preview

Occasionally, Glacier displays a gray placeholder box where a link, image, or video preview should appear. This happens when the app starts fetching preview details (like the thumbnail and title) but runs into an issue and never marks the request as finished. Because the fetch is stuck in a "still working" state, Glacier keeps showing the placeholder and skips new attempts, leaving the gray box on screen.

Two situations commonly trigger this:

1. **Missing or bad metadata from the link provider.** If a website doesn't return the expected preview information (or blocks the request), Glacier gives up but forgets to clear its "I'm still loading" marker. With that marker set, future retries don't start, so the gray box persists instead of being replaced by the preview.
2. **Interrupted image generation.** Even when some data is returned, creating the preview image can fail or time out. If Glacier doesn't reset its loading indicator after the failure, it never tries again, so the placeholder remains.

The recent fix makes sure the app always clears the "still loading" flag when metadata is missing or a preview can't be generated. Once that flag is removed, Glacier can retry the fetch on the next pass instead of leaving the gray placeholder in place.
