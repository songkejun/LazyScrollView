//
//  TMLazyScrollView.m
//  LazyScrollView
//
//  Copyright (c) 2015-2018 Alibaba. All rights reserved.
//

#import "TMLazyScrollView.h"
#import <objc/runtime.h>
#import "TMLazyItemViewProtocol.h"
#import "UIView+TMLazyScrollView.h"

#define LazyBufferHeight 20.0
#define LazyHalfBufferHeight (LazyBufferHeight / 2.0)

@interface TMLazyScrollView () {
    NSMutableSet<UIView *> *_visibleItems;
    NSMutableSet<UIView *> *_inScreenVisibleItems;
    
    // Store item models.
    NSMutableArray<TMLazyItemModel *> *_itemsFrames;
    
    // Store reuseable cells by reuseIdentifier.
    NSMutableDictionary<NSString *, NSMutableSet<UIView *> *> *_recycledIdentifierItemsDic;
    // Store reuseable cells by muiID.
    NSMutableDictionary<NSString *, UIView *> *_recycledMuiIDItemsDic;
    
    // Store view models below contentOffset of ScrollView
    NSMutableSet<NSString *> *_firstSet;
    // Store view models above contentOffset + height of ScrollView
    NSMutableSet<NSString *> *_secondSet;
    
    // View Model sorted by Top Edge.
    NSArray<TMLazyItemModel *> *_modelsSortedByTop;
    // View Model sorted by Bottom Edge.
    NSArray<TMLazyItemModel *> *_modelsSortedByBottom;
    
    // It is used to store views need to assign new value after reload.
    NSMutableSet<NSString *> *_shouldReloadItems;
    
    // Store the times of view entered the screen, the key is muiID.
    NSMutableDictionary<NSString *, NSNumber *> *_enterDic;
    
    // Record current muiID of visible view for calculate.
    // Will be used for dequeueReusableItem methods.
    NSString *_currentVisibleItemMuiID;
    
    // Record muiIDs of visible items. Used for calc enter times.
    NSSet<NSString *> *_muiIDOfVisibleViews;
    // Store last time visible muiID. Used for calc enter times.
    NSSet<NSString *> *_lastVisibleMuiID;
    
    TMLazyScrollViewObserver *_outerScrollViewObserver;
    
    BOOL _forwardingDelegateCanPerformScrollViewDidScrollSelector;
    
    @package
    // Record contentOffset of scrollview in previous time that calculate
    // views to show
    CGPoint _lastScrollOffset;
}

@end

@implementation TMLazyScrollView

#pragma mark - Getter & Setter

- (NSSet *)inScreenVisibleItems
{
    return [_inScreenVisibleItems copy];
}

- (NSSet *)visibleItems
{
    return [_visibleItems copy];
}

-(void)setOuterScrollView:(UIScrollView *)outerScrollView
{
    _outerScrollView = outerScrollView;
    if (_outerScrollViewObserver == nil) {
        _outerScrollViewObserver = [[TMLazyScrollViewObserver alloc]init];
        _outerScrollViewObserver.lazyScrollView = self;
    }
    
    @try {
        [outerScrollView removeObserver:_outerScrollViewObserver forKeyPath:@"contentOffset"];
    }
    @catch (NSException * __unused exception) {}
    [outerScrollView addObserver:_outerScrollViewObserver
                      forKeyPath:@"contentOffset"
                         options:NSKeyValueObservingOptionNew
                         context:nil];
}

#pragma mark - Lifecycle

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.clipsToBounds = YES;
        self.autoresizesSubviews = NO;
        self.showsHorizontalScrollIndicator = NO;
        self.showsVerticalScrollIndicator = NO;
        
        _shouldReloadItems = [[NSMutableSet alloc] init];
        
        _modelsSortedByTop = [[NSArray alloc] init];
        _modelsSortedByBottom = [[NSArray alloc]init];
        
        _recycledIdentifierItemsDic = [[NSMutableDictionary alloc] init];
        _recycledMuiIDItemsDic = [[NSMutableDictionary alloc] init];
        
        _visibleItems = [[NSMutableSet alloc] init];
        _inScreenVisibleItems = [[NSMutableSet alloc] init];
        
        _itemsFrames = [[NSMutableArray alloc] init];
        
        _firstSet = [[NSMutableSet alloc] initWithCapacity:30];
        _secondSet = [[NSMutableSet alloc] initWithCapacity:30];
        
        _enterDic = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    _dataSource = nil;
    self.delegate = nil;
    if (_outerScrollView) {
        @try {
            [_outerScrollView removeObserver:_outerScrollViewObserver forKeyPath:@"contentOffset"];
        }
        @catch (NSException *exception) {
            
        }
    }
}

#pragma mark - ScrollEvent

- (void)setContentOffset:(CGPoint)contentOffset
{
    [super setContentOffset:contentOffset];
    // Calculate which views should be shown.
    // Calcuting will cost some time, so here is a buffer for reducing
    // times of calculating.
    CGFloat currentY = contentOffset.y;
    CGFloat buffer = LazyHalfBufferHeight;
    if (buffer < ABS(currentY - _lastScrollOffset.y)) {
        _lastScrollOffset = self.contentOffset;
        [self assembleSubviews];
        [self findViewsInVisibleRect];
    }
}

#pragma mark - Core Logic

// Do Binary search here to find index in view model array.
- (NSUInteger)binarySearchForIndex:(NSArray *)frameArray baseLine:(CGFloat)baseLine isFromTop:(BOOL)fromTop
{
    NSInteger min = 0;
    NSInteger max = frameArray.count - 1;
    NSInteger mid = ceilf((min + max) * 0.5f);
    while (mid > min && mid < max) {
        CGRect rect = [(TMLazyItemModel *)[frameArray tm_safeObjectAtIndex:mid] absRect];
        // For top
        if(fromTop) {
            CGFloat itemTop = CGRectGetMinY(rect);
            if (itemTop <= baseLine) {
                CGRect nextItemRect = [(TMLazyItemModel *)[frameArray tm_safeObjectAtIndex:mid + 1] absRect];
                CGFloat nextTop = CGRectGetMinY(nextItemRect);
                if (nextTop > baseLine) {
                    break;
                }
                min = mid;
            } else {
                max = mid;
            }
        }
        // For bottom
        else {
            CGFloat itemBottom = CGRectGetMaxY(rect);
            if (itemBottom >= baseLine) {
                CGRect nextItemRect = [(TMLazyItemModel *)[frameArray tm_safeObjectAtIndex:mid + 1] absRect];
                CGFloat nextBottom = CGRectGetMaxY(nextItemRect);
                if (nextBottom < baseLine) {
                    break;
                }
                min = mid;
            } else {
                max = mid;
            }
        }
        mid = ceilf((CGFloat)(min + max) / 2.f);
    }
    return mid;
}

// Get which views should be shown in LazyScrollView.
// The kind of values In NSSet is muiID.
- (NSSet<NSString *> *)showingItemIndexSetFrom:(CGFloat)startY to:(CGFloat)endY
{
    NSUInteger endBottomIndex = [self binarySearchForIndex:_modelsSortedByBottom baseLine:startY isFromTop:NO];
    [_firstSet removeAllObjects];
    for (NSUInteger i = 0; i <= endBottomIndex; i++) {
        TMLazyItemModel *model = [_modelsSortedByBottom tm_safeObjectAtIndex:i];
        if (model != nil) {
            [_firstSet addObject:model.muiID];
        }
    }
    
    NSUInteger endTopIndex = [self binarySearchForIndex:_modelsSortedByTop baseLine:endY isFromTop:YES];
    [_secondSet removeAllObjects];
    for (NSInteger i = 0; i <= endTopIndex; i++) {
        TMLazyItemModel *model = [_modelsSortedByTop tm_safeObjectAtIndex:i];
        if (model != nil) {
            [_secondSet addObject:model.muiID];
        }
    }
    
    [_firstSet intersectSet:_secondSet];
    return [_firstSet copy];
}

// Get view models from delegate. Create to indexes for sorting.
- (void)creatScrollViewIndex
{
    NSUInteger count = 0;
    if (_dataSource &&
        [_dataSource conformsToProtocol:@protocol(TMLazyScrollViewDataSource)] &&
        [_dataSource respondsToSelector:@selector(numberOfItemsInScrollView:)]) {
        count = [_dataSource numberOfItemsInScrollView:self];
    }
    
    [_itemsFrames removeAllObjects];
    for (NSUInteger i = 0 ; i < count ; i++) {
        TMLazyItemModel *rectmodel = nil;
        if (_dataSource &&
            [_dataSource conformsToProtocol:@protocol(TMLazyScrollViewDataSource)] &&
            [_dataSource respondsToSelector:@selector(scrollView:itemModelAtIndex:)]) {
            rectmodel = [_dataSource scrollView:self itemModelAtIndex:i];
            if (rectmodel.muiID.length == 0) {
                rectmodel.muiID = [NSString stringWithFormat:@"%lu", (unsigned long)i];
            }
        }
        [_itemsFrames tm_safeAddObject:rectmodel];
    }
    
    _modelsSortedByTop = [_itemsFrames sortedArrayUsingComparator:^NSComparisonResult(id obj1 ,id obj2) {
                                 CGRect rect1 = [(TMLazyItemModel *) obj1 absRect];
                                 CGRect rect2 = [(TMLazyItemModel *) obj2 absRect];
                                 if (rect1.origin.y < rect2.origin.y) {
                                     return NSOrderedAscending;
                                 }  else if (rect1.origin.y > rect2.origin.y) {
                                     return NSOrderedDescending;
                                 } else {
                                     return NSOrderedSame;
                                 }
                             }];
    
    _modelsSortedByBottom = [_itemsFrames sortedArrayUsingComparator:^NSComparisonResult(id obj1 ,id obj2) {
                                    CGRect rect1 = [(TMLazyItemModel *) obj1 absRect];
                                    CGRect rect2 = [(TMLazyItemModel *) obj2 absRect];
                                    CGFloat bottom1 = CGRectGetMaxY(rect1);
                                    CGFloat bottom2 = CGRectGetMaxY(rect2);
                                    if (bottom1 > bottom2) {
                                        return NSOrderedAscending;
                                    } else if (bottom1 < bottom2) {
                                        return  NSOrderedDescending;
                                    } else {
                                        return NSOrderedSame;
                                    }
                                }];
}

- (void)findViewsInVisibleRect
{
    NSMutableSet *itemViewSet = [_muiIDOfVisibleViews mutableCopy];
    [itemViewSet minusSet:_lastVisibleMuiID];
    for (UIView *view in _visibleItems) {
        if (view && [itemViewSet containsObject:view.muiID]) {
            if ([view conformsToProtocol:@protocol(TMLazyItemViewProtocol)] &&
                [view respondsToSelector:@selector(mui_didEnterWithTimes:)]) {
                NSUInteger times = 0;
                if ([_enterDic tm_safeObjectForKey:view.muiID] != nil) {
                    times = [_enterDic tm_integerForKey:view.muiID] + 1;
                }
                NSNumber *showTimes = [NSNumber numberWithUnsignedInteger:times];
                [_enterDic tm_safeSetObject:showTimes forKey:view.muiID];
                [(UIView<TMLazyItemViewProtocol> *)view mui_didEnterWithTimes:times];
            }
        }
    }
    _lastVisibleMuiID = [_muiIDOfVisibleViews copy];
}

// A simple method to show view that should be shown in LazyScrollView.
- (void)assembleSubviews
{
    if (_outerScrollView) {
        CGPoint pointInScrollView = [self.superview convertPoint:self.frame.origin toView:_outerScrollView];
        CGFloat minY = _outerScrollView.contentOffset.y  - pointInScrollView.y - LazyHalfBufferHeight;
        //maxY 计算的逻辑，需要修改，增加的height，需要计算的更加明确
        CGFloat maxY = _outerScrollView.contentOffset.y + _outerScrollView.frame.size.height - pointInScrollView.y + LazyHalfBufferHeight;
        if (maxY > 0) {
            [self assembleSubviewsForReload:NO minY:minY maxY:maxY];
        }
        
    }
    else
    {
        CGRect visibleBounds = self.bounds;
        CGFloat minY = CGRectGetMinY(visibleBounds) - LazyBufferHeight;
        CGFloat maxY = CGRectGetMaxY(visibleBounds) + LazyBufferHeight;
        [self assembleSubviewsForReload:NO minY:minY maxY:maxY];
    }
}

- (void)assembleSubviewsForReload:(BOOL)isReload minY:(CGFloat)minY maxY:(CGFloat)maxY
{
    NSSet<NSString *> *itemShouldShowSet = [self showingItemIndexSetFrom:minY to:maxY];
    if (_outerScrollView) {
        _muiIDOfVisibleViews = [self showingItemIndexSetFrom:minY to:maxY];
    }
    else{
        _muiIDOfVisibleViews = [self showingItemIndexSetFrom:CGRectGetMinY(self.bounds) to:CGRectGetMaxY(self.bounds)];
    }
    NSMutableSet<UIView *> *recycledItems = [[NSMutableSet alloc] init];
    // For recycling. Find which views should not in visible area.
    NSSet *visibles = [_visibleItems copy];
    for (UIView *view in visibles) {
        // Make sure whether the view should be shown.
        BOOL isToShow  = [itemShouldShowSet containsObject:view.muiID];
        if (!isToShow) {
            if ([view respondsToSelector:@selector(mui_didLeave)]){
                [(UIView<TMLazyItemViewProtocol> *)view mui_didLeave];
            }
            // If this view should be recycled and the length of its reuseidentifier is over 0.
            if (view.reuseIdentifier.length > 0) {
                // Then recycle the view.
                NSMutableSet<UIView *> *recycledIdentifierSet = [self recycledIdentifierSet:view.reuseIdentifier];
                [recycledIdentifierSet addObject:view];
                view.hidden = YES;
                [recycledItems addObject:view];
                // Also add to muiID recycle dict.
                [_recycledMuiIDItemsDic tm_safeSetObject:view forKey:view.muiID];
            } else if(isReload && view.muiID) {
                // Need to reload unreusable views.
                [_shouldReloadItems addObject:view.muiID];
            }
        } else if (isReload && view.muiID) {
            [_shouldReloadItems addObject:view.muiID];
        }
        
    }
    [_visibleItems minusSet:recycledItems];
    [recycledItems removeAllObjects];
    // Creare new view.
    for (NSString *muiID in itemShouldShowSet) {
        BOOL shouldReload = isReload || [_shouldReloadItems containsObject:muiID];
        if (![self isCellVisible:muiID] || [_shouldReloadItems containsObject:muiID]) {
            if (_dataSource &&
                [_dataSource conformsToProtocol:@protocol(TMLazyScrollViewDataSource)] &&
                [_dataSource respondsToSelector:@selector(scrollView:itemByMuiID:)]) {
                // Create view by dataSource.
                // If you call dequeue method in your dataSource, the currentVisibleItemMuiID
                // will be used for searching reusable view.
                if (shouldReload) {
                    _currentVisibleItemMuiID = muiID;
                }
                UIView *viewToShow = [_dataSource scrollView:self itemByMuiID:muiID];
                _currentVisibleItemMuiID = nil;
                // Call afterGetView.
                if ([viewToShow conformsToProtocol:@protocol(TMLazyItemViewProtocol)] &&
                    [viewToShow respondsToSelector:@selector(mui_afterGetView)]) {
                    [(UIView<TMLazyItemViewProtocol> *)viewToShow mui_afterGetView];
                }
                if (viewToShow) {
                    viewToShow.muiID = muiID;
                    viewToShow.hidden = NO;
                    if (![_visibleItems containsObject:viewToShow]) {
                        [_visibleItems addObject:viewToShow];
                    }
                    if (_autoAddSubview) {
                        if (viewToShow.superview != self) {
                            [self addSubview:viewToShow];
                        }
                    }
                }
            }
            [_shouldReloadItems removeObject:muiID];
        }
    }
    [_inScreenVisibleItems removeAllObjects];
    for (UIView *view in _visibleItems) {
        if ([view isKindOfClass:[UIView class]] && view.superview) {
            CGRect absRect = [view.superview convertRect:view.frame toView:self];
            if ((absRect.origin.y + absRect.size.height >= CGRectGetMinY(self.bounds)) &&
                (absRect.origin.y <= CGRectGetMaxY(self.bounds))) {
                [_inScreenVisibleItems addObject:view];
            }
        }
    }
}

// Get NSSet accroding to reuse identifier.
- (NSMutableSet<UIView *> *)recycledIdentifierSet:(NSString *)reuseIdentifier;
{
    if (reuseIdentifier.length == 0) {
        return nil;
    }
    
    NSMutableSet<UIView *> *result = [_recycledIdentifierItemsDic tm_safeObjectForKey:reuseIdentifier];
    if (result == nil) {
        result = [[NSMutableSet alloc] init];
        [_recycledIdentifierItemsDic setObject:result forKey:reuseIdentifier];
    }
    return result;
}

// Reloads everything and redisplays visible views.
- (void)reloadData
{
    [self creatScrollViewIndex];
    if (_itemsFrames.count > 0) {
        if (_outerScrollView) {
            CGRect rectInScrollView = [self convertRect:self.frame toView:_outerScrollView];
            CGFloat minY = _outerScrollView.contentOffset.y - rectInScrollView.origin.y - LazyBufferHeight;
            CGFloat maxY = _outerScrollView.contentOffset.y + _outerScrollView.frame.size.height - rectInScrollView.origin.y + _outerScrollView.frame.size.height + LazyBufferHeight;
            if (maxY > 0) {
                [self assembleSubviewsForReload:YES minY:minY maxY:maxY];
            }
        }
        else{
            CGRect visibleBounds = self.bounds;
            // 上下增加 20point 的缓冲区
            CGFloat minY = CGRectGetMinY(visibleBounds) - LazyBufferHeight;
            CGFloat maxY = CGRectGetMaxY(visibleBounds) + LazyBufferHeight;
            [self assembleSubviewsForReload:YES minY:minY maxY:maxY];
        }
        [self findViewsInVisibleRect];
    }

}

// To acquire an already allocated view that can be reused by reuse identifier.
- (UIView *)dequeueReusableItemWithIdentifier:(NSString *)identifier
{
    return [self dequeueReusableItemWithIdentifier:identifier muiID:nil];
}

// To acquire an already allocated view that can be reused by reuse identifier.
// Use muiID for higher priority.
- (UIView *)dequeueReusableItemWithIdentifier:(NSString *)identifier muiID:(NSString *)muiID
{
    UIView *view = nil;
    
    if (_currentVisibleItemMuiID) {
        NSSet *visibles = _visibleItems;
        for (UIView *v in visibles) {
            if ([v.muiID isEqualToString:_currentVisibleItemMuiID] && [v.reuseIdentifier isEqualToString:identifier]) {
                view = v;
                break;
            }
        }
    } else if(muiID && [muiID isKindOfClass:[NSString class]] && muiID.length > 0) {
        // Try to get reusable view from muiID dict.
        view = [_recycledMuiIDItemsDic tm_safeObjectForKey:muiID class:[UIView class]];
        if (view && view.reuseIdentifier.length > 0 && [view.reuseIdentifier isEqualToString:identifier])
        {
            NSMutableSet *recycledIdentifierSet = [self recycledIdentifierSet:identifier];
            if (muiID && [muiID isKindOfClass:[NSString class]] && muiID.length > 0) {
                [_recycledMuiIDItemsDic removeObjectForKey:muiID];
            }
            [recycledIdentifierSet removeObject:view];
            view.gestureRecognizers = nil;
        } else {
            view = nil;
        }
    }

    if (nil == view) {
        NSMutableSet *recycledIdentifierSet = [self recycledIdentifierSet:identifier];
        view = [recycledIdentifierSet anyObject];
        if (view && view.reuseIdentifier.length > 0) {
            // If exist reusable view, remove it from recycledSet and recycledMuiIDItemsDic.
            if (view.muiID && [view.muiID isKindOfClass:[NSString class]] && view.muiID.length > 0) {
                [_recycledMuiIDItemsDic removeObjectForKey:view.muiID];
            }
            [recycledIdentifierSet removeObject:view];
            // Then remove all gesture recognizers of it.
            view.gestureRecognizers = nil;
        } else {
            view = nil;
        }
    }
   
    if ([view conformsToProtocol:@protocol(TMLazyItemViewProtocol)] && [view respondsToSelector:@selector(mui_prepareForReuse)]) {
        [(UIView<TMLazyItemViewProtocol> *)view mui_prepareForReuse];
    }
    return view;
}

//Make sure whether the view is visible accroding to muiID.
- (BOOL)isCellVisible:(NSString *)muiID
{
    BOOL result = NO;
    NSSet *visibles = [_visibleItems copy];
    for (UIView *view in visibles) {
        if ([view.muiID isEqualToString:muiID]) {
            result = YES;
            break;
        }
    }
    return result;
}

- (void)clearItemViewsAndReusePool
{
    NSSet *visibles = _visibleItems;
    for (UIView *view in visibles) {
        NSMutableSet *recycledIdentifierSet = [self recycledIdentifierSet:view.reuseIdentifier];
        [recycledIdentifierSet addObject:view];
        view.hidden = YES;
    }
    [_visibleItems removeAllObjects];
    [_recycledIdentifierItemsDic removeAllObjects];
    [_recycledMuiIDItemsDic removeAllObjects];
}

- (void)removeAllLayouts
{
    [self clearItemViewsAndReusePool];
}

- (void)resetItemViewsEnterTimes
{
    [_enterDic removeAllObjects];
    _lastVisibleMuiID = nil;
}

- (void)resetViewEnterTimes
{
    [self resetItemViewsEnterTimes];
}

@end

@implementation TMLazyScrollViewObserver

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if([keyPath isEqualToString:@"contentOffset"])
    {
        CGPoint newPoint = [[change objectForKey:NSKeyValueChangeNewKey] CGPointValue];
        CGFloat buffer = LazyHalfBufferHeight;
        if (buffer < ABS(newPoint.y - _lazyScrollView->_lastScrollOffset.y)) {
            _lazyScrollView->_lastScrollOffset = newPoint;
            [_lazyScrollView assembleSubviews];
            [_lazyScrollView findViewsInVisibleRect];
        }
    }
}

@end


