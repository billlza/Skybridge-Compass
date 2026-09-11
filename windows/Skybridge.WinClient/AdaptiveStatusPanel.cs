using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Skybridge.WinClient;

// Unlike a horizontal ScrollViewer, this keeps every status capsule intact when
// system caption buttons or display scaling leave less space in the title bar.
public sealed class AdaptiveStatusPanel : Panel
{
    private const double Gap = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        foreach (var child in Children)
        {
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            if (child.DesiredSize.Width > availableSize.Width)
                child.Measure(new Size(availableSize.Width, double.PositiveInfinity));
        }
        return Layout(availableSize.Width, arrange: false);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        Layout(finalSize.Width, arrange: true);
        return finalSize;
    }

    private Size Layout(double width, bool arrange)
    {
        double x = 0, y = 0, rowHeight = 0, occupiedWidth = 0;
        foreach (var child in Children)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            double itemWidth = System.Math.Min(child.DesiredSize.Width, width);
            double itemHeight = child.DesiredSize.Height;
            if (x > 0 && x + itemWidth > width)
            {
                y += rowHeight + Gap;
                x = 0;
                rowHeight = 0;
            }
            if (arrange) child.Arrange(new Rect(x, y, itemWidth, itemHeight));
            occupiedWidth = System.Math.Max(occupiedWidth, x + itemWidth);
            x += itemWidth + Gap;
            rowHeight = System.Math.Max(rowHeight, itemHeight);
        }
        return new Size(occupiedWidth, y + rowHeight);
    }
}
