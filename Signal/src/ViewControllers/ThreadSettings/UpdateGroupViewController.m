//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

#import "UpdateGroupViewController.h"
#import "AvatarViewHelper.h"
#import "OWSNavigationController.h"
#import "Signal-Swift.h"
#import "ViewControllerUtils.h"
#import <PromiseKit/AnyPromise.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/NSString+OWS.h>
#import <SignalMessaging/BlockListUIUtils.h>
#import <SignalMessaging/ContactTableViewCell.h>
#import <SignalMessaging/ContactsViewHelper.h>
#import <SignalMessaging/Environment.h>
#import <SignalMessaging/OWSContactsManager.h>
#import <SignalMessaging/OWSTableViewController.h>
#import <SignalMessaging/UIUtil.h>
#import <SignalMessaging/UIView+OWS.h>
#import <SignalMessaging/UIViewController+OWS.h>
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/TSGroupModel.h>
#import <SignalServiceKit/TSGroupThread.h>
#import <SignalServiceKit/TSOutgoingMessage.h>

NS_ASSUME_NONNULL_BEGIN

@interface UpdateGroupViewController () <UIImagePickerControllerDelegate,
    UITextFieldDelegate,
    AvatarViewHelperDelegate,
    RecipientPickerDelegate,
    UINavigationControllerDelegate,
    OWSNavigationView>

@property (nonatomic, readonly) TSGroupThread *thread;
@property (nonatomic, readonly) UpdateGroupMode mode;

@property (nonatomic, readonly) OWSMessageSender *messageSender;
@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;
@property (nonatomic, readonly) AvatarViewHelper *avatarViewHelper;

@property (nonatomic, readonly) RecipientPickerViewController *recipientPicker;
@property (nonatomic, readonly) AvatarImageView *avatarView;
@property (nonatomic, readonly) UIImageView *cameraImageView;
@property (nonatomic, readonly) UITextField *groupNameTextField;

@property (nonatomic) TSGroupModel *oldGroupModel;
@property (nonatomic, nullable) NSData *groupAvatarData;
@property (nonatomic, nullable) NSSet<PickedRecipient *> *previousMemberRecipients;
@property (nonatomic) NSMutableSet<PickedRecipient *> *memberRecipients;

// If there are unsaved changes, this group model reflects them.
// If not, it is nil.
@property (nonatomic, nullable) TSGroupModel *unsavedChangeGroupModel;

@end

#pragma mark -

@implementation UpdateGroupViewController

#pragma mark - Dependencies

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

#pragma mark -

- (instancetype)initWithGroupThread:(TSGroupThread *)groupThread mode:(UpdateGroupMode)mode
{
    OWSAssertDebug(groupThread);

    self = [super init];
    if (!self) {
        return self;
    }

    _thread = groupThread;
    _mode = mode;

    [self commonInit];

    return self;
}

- (void)commonInit
{
    _messageSender = SSKEnvironment.shared.messageSender;
    _avatarViewHelper = [AvatarViewHelper new];
    _avatarViewHelper.delegate = self;

    self.memberRecipients = [NSMutableSet new];
}

#pragma mark - View Lifecycle

- (void)loadView
{
    [super loadView];

    self.view.backgroundColor = Theme.backgroundColor;

    [self.memberRecipients
        addObjectsFromArray:[self.thread.groupModel.groupMembers map:^(SignalServiceAddress *address) {
            return [PickedRecipient forAddress:address];
        }]];
    self.previousMemberRecipients = [self.memberRecipients copy];
    self.oldGroupModel = self.thread.groupModel;

    self.title = NSLocalizedString(@"EDIT_GROUP_DEFAULT_TITLE", @"The navbar title for the 'update group' view.");

    // First section.

    UIView *firstSection = [self firstSectionHeader];
    [self.view addSubview:firstSection];
    [firstSection autoSetDimension:ALDimensionHeight toSize:100.f];
    [firstSection autoPinWidthToSuperview];
    [firstSection autoPinToTopLayoutGuideOfViewController:self withInset:0];

    _recipientPicker = [RecipientPickerViewController new];
    self.recipientPicker.delegate = self;
    self.recipientPicker.shouldShowGroups = NO;
    self.recipientPicker.allowsSelectingUnregisteredPhoneNumbers = NO;
    self.recipientPicker.shouldShowAlphabetSlider = NO;
    self.recipientPicker.pickedRecipients = self.memberRecipients.allObjects;

    [self addChildViewController:self.recipientPicker];
    [self.view addSubview:self.recipientPicker.view];
    [self.recipientPicker.view autoPinEdgeToSuperviewSafeArea:ALEdgeLeading];
    [self.recipientPicker.view autoPinEdgeToSuperviewSafeArea:ALEdgeTrailing];
    [self.recipientPicker.view autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:firstSection];
    [self.recipientPicker.view autoPinEdgeToSuperviewEdge:ALEdgeBottom];
}

- (void)updateHasUnsavedChanges
{
    TSGroupModel *_Nullable newGroupModel = [self buildNewGroupModelIfHasUnsavedChanges];
    BOOL didChange = ![NSObject isNullableObject:newGroupModel equalTo:self.unsavedChangeGroupModel];
    self.unsavedChangeGroupModel = newGroupModel;
    if (didChange) {
        [self updateNavigationBar];
    }
}

- (BOOL)hasUnsavedChanges
{
    return self.unsavedChangeGroupModel != nil;
}

- (void)updateNavigationBar
{
    self.navigationItem.rightBarButtonItem = (self.hasUnsavedChanges
            ? [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"EDIT_GROUP_UPDATE_BUTTON",
                                                         @"The title for the 'update group' button.")
                                               style:UIBarButtonItemStylePlain
                                              target:self
                                              action:@selector(updateGroupPressed)
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"update")]
            : nil);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    switch (self.mode) {
        case UpdateGroupModeEditGroupName:
            [self.groupNameTextField becomeFirstResponder];
            break;
        case UpdateGroupModeEditGroupAvatar:
            [self showChangeAvatarUI];
            break;
        default:
            break;
    }
    // Only perform these actions the first time the view appears.
    _mode = UpdateGroupModeDefault;
}

- (UIView *)firstSectionHeader
{
    OWSAssertDebug(self.thread);
    OWSAssertDebug(self.thread.groupModel);

    UIView *firstSectionHeader = [UIView new];
    firstSectionHeader.userInteractionEnabled = YES;
    [firstSectionHeader
        addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(headerWasTapped:)]];
    firstSectionHeader.backgroundColor = [Theme backgroundColor];
    UIView *threadInfoView = [UIView new];
    [firstSectionHeader addSubview:threadInfoView];
    [threadInfoView autoPinWidthToSuperviewWithMargin:16.f];
    [threadInfoView autoPinHeightToSuperviewWithMargin:16.f];

    AvatarImageView *avatarView = [AvatarImageView new];
    _avatarView = avatarView;

    [threadInfoView addSubview:avatarView];
    [avatarView autoVCenterInSuperview];
    [avatarView autoPinLeadingToSuperviewMargin];
    [avatarView autoSetDimension:ALDimensionWidth toSize:kMediumAvatarSize];
    [avatarView autoSetDimension:ALDimensionHeight toSize:kMediumAvatarSize];
    _groupAvatarData = self.thread.groupModel.groupAvatarData;

    UIImageView *cameraImageView = [UIImageView new];
    [cameraImageView setTemplateImageName:@"camera-outline-24" tintColor:Theme.secondaryTextAndIconColor];
    [threadInfoView addSubview:cameraImageView];

    [cameraImageView autoSetDimensionsToSize:CGSizeMake(32, 32)];
    cameraImageView.contentMode = UIViewContentModeCenter;
    cameraImageView.backgroundColor = Theme.backgroundColor;
    cameraImageView.layer.cornerRadius = 16;
    cameraImageView.layer.shadowColor =
        [(Theme.isDarkThemeEnabled ? Theme.darkThemeWashColor : Theme.primaryTextColor) CGColor];
    cameraImageView.layer.shadowOffset = CGSizeMake(1, 1);
    cameraImageView.layer.shadowOpacity = 0.5;
    cameraImageView.layer.shadowRadius = 4;

    [cameraImageView autoPinTrailingToEdgeOfView:avatarView];
    [cameraImageView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:avatarView];
    _cameraImageView = cameraImageView;

    [self updateAvatarView];

    UITextField *groupNameTextField = [OWSTextField new];
    _groupNameTextField = groupNameTextField;
    self.groupNameTextField.text = [self.thread.groupModel.groupName ows_stripped];
    groupNameTextField.textColor = Theme.primaryTextColor;
    groupNameTextField.font = [UIFont ows_dynamicTypeTitle2Font];
    groupNameTextField.placeholder
        = NSLocalizedString(@"NEW_GROUP_NAMEGROUP_REQUEST_DEFAULT", @"Placeholder text for group name field");
    groupNameTextField.delegate = self;
    [groupNameTextField addTarget:self
                           action:@selector(groupNameDidChange:)
                 forControlEvents:UIControlEventEditingChanged];
    [threadInfoView addSubview:groupNameTextField];
    [groupNameTextField autoVCenterInSuperview];
    [groupNameTextField autoPinTrailingToSuperviewMargin];
    [groupNameTextField autoPinLeadingToTrailingEdgeOfView:avatarView offset:16.f];
    SET_SUBVIEW_ACCESSIBILITY_IDENTIFIER(self, groupNameTextField);

    [avatarView
        addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTouched:)]];
    avatarView.userInteractionEnabled = YES;
    SET_SUBVIEW_ACCESSIBILITY_IDENTIFIER(self, avatarView);

    return firstSectionHeader;
}

- (void)headerWasTapped:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self.groupNameTextField becomeFirstResponder];
    }
}

- (void)avatarTouched:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self showChangeAvatarUI];
    }
}

- (void)addRecipient:(PickedRecipient *)recipient
{
    OWSAssertDebug(recipient.address.isValid);

    if (![self canAddOrInviteMemberWithOldGroupModel:self.oldGroupModel address:recipient.address]) {
        [OWSActionSheets showActionSheetWithTitle:NSLocalizedString(@"GROUP_CANNOT_ADD_INVALID_MEMBER",
                                                      @"Error indicating that a member cannot be added to a group.")];
    } else {
        [self.memberRecipients addObject:recipient];
        self.recipientPicker.pickedRecipients = self.memberRecipients.allObjects;
        [self updateHasUnsavedChanges];
    }
}

- (void)removeRecipient:(PickedRecipient *)recipient
{
    OWSAssertDebug(recipient.address.isValid);

    [self.memberRecipients removeObject:recipient];
    self.recipientPicker.pickedRecipients = self.memberRecipients.allObjects;
    [self updateHasUnsavedChanges];
}

#pragma mark - Methods

- (void)updateGroupWithNewGroupModel:(TSGroupModel *)newGroupModel
{
    OWSAssertDebug(self.conversationSettingsViewDelegate);

    id<OWSConversationSettingsViewDelegate> _Nullable delegate = self.conversationSettingsViewDelegate;
    if (delegate == nil) {
        OWSFailDebug(@"Missing delegate.");
        return;
    }
    [self updateGroupThreadWithOldGroupModel:self.oldGroupModel newGroupModel:newGroupModel delegate:delegate];
}

#pragma mark - Group Avatar

- (void)showChangeAvatarUI
{
    [self.groupNameTextField resignFirstResponder];

    [self.avatarViewHelper showChangeAvatarUI];
}

- (void)setGroupAvatarData:(nullable NSData *)groupAvatarData
{
    OWSAssertIsOnMainThread();

    _groupAvatarData = groupAvatarData;

    [self updateAvatarView];

    [self updateHasUnsavedChanges];
}

- (void)updateAvatarView
{
    UIImage *_Nullable groupAvatar;
    if (self.groupAvatarData.length > 0) {
        groupAvatar = [UIImage imageWithData:self.groupAvatarData];
    }
    self.cameraImageView.hidden = groupAvatar != nil;

    if (!groupAvatar) {
        groupAvatar = [[[OWSGroupAvatarBuilder alloc] initWithThread:self.thread diameter:kMediumAvatarSize] build];
    }

    self.avatarView.image = groupAvatar;
}

#pragma mark - Event Handling

- (nullable TSGroupModel *)buildNewGroupModelIfHasUnsavedChanges
{
    [self.groupNameTextField acceptAutocorrectSuggestion];

    NSString *_Nullable newTitle = self.groupNameTextField.text.ows_stripped;
    NSData *_Nullable newAvatarData = self.groupAvatarData;
    NSArray<SignalServiceAddress *> *memberList = [self.memberRecipients.allObjects map:^(PickedRecipient *recipient) {
        OWSAssertDebug(recipient.address.isValid);
        return recipient.address;
    }];
    NSMutableSet<SignalServiceAddress *> *memberSet = [NSMutableSet setWithArray:memberList];
    [memberSet addObject:self.tsAccountManager.localAddress];
    TSGroupModel *newGroupModel = [self buildNewGroupModelWithOldGroupModel:self.oldGroupModel
                                                                   newTitle:newTitle
                                                              newAvatarData:newAvatarData
                                                                  v1Members:memberSet];
    if ([self.oldGroupModel isEqualToGroupModel:newGroupModel ignoreRevision:YES]) {
        return nil;
    }
    return newGroupModel;
}

- (void)backButtonPressed
{
    [self.groupNameTextField resignFirstResponder];

    if (self.unsavedChangeGroupModel == nil) {
        // If user made no changes, return to conversation settings view.
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    TSGroupModel *newGroupModel = self.unsavedChangeGroupModel;

    ActionSheetController *alert = [[ActionSheetController alloc]
        initWithTitle:NSLocalizedString(@"EDIT_GROUP_VIEW_UNSAVED_CHANGES_TITLE",
                          @"The alert title if user tries to exit update group view without saving changes.")
              message:NSLocalizedString(@"EDIT_GROUP_VIEW_UNSAVED_CHANGES_MESSAGE",
                          @"The alert message if user tries to exit update group view without saving changes.")];
    [alert addAction:[[ActionSheetAction alloc] initWithTitle:NSLocalizedString(@"ALERT_SAVE",
                                                                  @"The label for the 'save' button in action sheets.")
                                      accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"save")
                                                        style:ActionSheetActionStyleDefault
                                                      handler:^(ActionSheetAction *action) {
                                                          OWSAssertDebug(self.conversationSettingsViewDelegate);

                                                          [self updateGroupWithNewGroupModel:newGroupModel];
                                                      }]];
    [alert addAction:[[ActionSheetAction alloc]
                                   initWithTitle:NSLocalizedString(@"ALERT_DONT_SAVE",
                                                     @"The label for the 'don't save' button in action sheets.")
                         accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"dont_save")
                                           style:ActionSheetActionStyleDestructive
                                         handler:^(ActionSheetAction *action) {
                                             [self.navigationController popViewControllerAnimated:YES];
                                         }]];
    [self presentActionSheet:alert];
}

- (void)updateGroupPressed
{
    OWSAssertDebug(self.conversationSettingsViewDelegate);

    if (self.unsavedChangeGroupModel == nil) {
        OWSFailDebug(@"This button should not be enabled if there are no unsaved changes.");
        // If user made no changes, return to conversation settings view.
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    TSGroupModel *newGroupModel = self.unsavedChangeGroupModel;

    [self updateGroupWithNewGroupModel:newGroupModel];
}

- (void)groupNameDidChange:(id)sender
{
    [self updateHasUnsavedChanges];
}

#pragma mark - Text Field Delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self.groupNameTextField resignFirstResponder];
    return NO;
}

#pragma mark - AvatarViewHelperDelegate

- (nullable NSString *)avatarActionSheetTitle
{
    return NSLocalizedString(
        @"NEW_GROUP_ADD_PHOTO_ACTION", @"Action Sheet title prompting the user for a group avatar");
}

- (void)avatarDidChange:(UIImage *)image
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(image);

    self.groupAvatarData = [TSGroupModel dataForGroupAvatar:image];
}

- (UIViewController *)fromViewController
{
    return self;
}

- (BOOL)hasClearAvatarAction
{
    return NO;
}

#pragma mark - RecipientPickerDelegate

- (void)recipientPicker:(RecipientPickerViewController *)recipientPickerViewController
     didSelectRecipient:(PickedRecipient *)recipient
{
    OWSAssertDebug(recipient.address.isValid);

    __weak __typeof(self) weakSelf;
    BOOL isPreviousMember = [self.previousMemberRecipients containsObject:recipient];
    BOOL isCurrentMember = [self.memberRecipients containsObject:recipient];
    BOOL isBlocked = [self.recipientPicker.contactsViewHelper isSignalServiceAddressBlocked:recipient.address];
    if (isPreviousMember) {
        [OWSActionSheets
            showActionSheetWithTitle:NSLocalizedString(@"UPDATE_GROUP_CANT_REMOVE_MEMBERS_ALERT_TITLE",
                                         @"Title for alert indicating that group members can't be removed.")
                             message:NSLocalizedString(@"UPDATE_GROUP_CANT_REMOVE_MEMBERS_ALERT_MESSAGE",
                                         @"Title for alert indicating that group members can't "
                                         @"be removed.")];
    } else if (isCurrentMember) {
        [self removeRecipient:recipient];
    } else if (isBlocked) {
        [BlockListUIUtils showUnblockAddressActionSheet:recipient.address
                                     fromViewController:self
                                        completionBlock:^(BOOL isStillBlocked) {
                                            if (!isStillBlocked) {
                                                [weakSelf addRecipient:recipient];
                                                [weakSelf.navigationController popToViewController:self animated:YES];
                                            }
                                        }];
    } else {
        BOOL didShowSNAlert = [SafetyNumberConfirmationAlert
            presentAlertIfNecessaryWithAddress:recipient.address
                              confirmationText:NSLocalizedString(@"SAFETY_NUMBER_CHANGED_CONFIRM_"
                                                                 @"ADD_TO_GROUP_ACTION",
                                                   @"button title to confirm adding "
                                                   @"a recipient to a group when "
                                                   @"their safety "
                                                   @"number has recently changed")
                                    completion:^(BOOL didConfirmIdentity) {
                                        if (didConfirmIdentity) {
                                            [weakSelf addRecipient:recipient];
                                            [weakSelf.navigationController popToViewController:self animated:YES];
                                        }
                                    }];
        if (didShowSNAlert) {
            return;
        }

        [self addRecipient:recipient];
        [self.navigationController popToViewController:self animated:YES];
    }
}

- (BOOL)recipientPicker:(RecipientPickerViewController *)recipientPickerViewController
     canSelectRecipient:(PickedRecipient *)recipient
{
    return YES;
}

- (void)recipientPicker:(RecipientPickerViewController *)recipientPickerViewController
    willRenderRecipient:(PickedRecipient *)recipient
{
    // Do nothing.
}

- (AnyPromise *)recipientPicker:(RecipientPickerViewController *)recipientPickerViewController
       prepareToSelectRecipient:(PickedRecipient *)recipient
{
    OWSFailDebug(@"This method should not called.");
    return [AnyPromise promiseWithValue:@(1)];
}

- (void)recipientPicker:(RecipientPickerViewController *)recipientPickerViewController
    showInvalidRecipientAlert:(PickedRecipient *)recipient
{
    OWSFailDebug(@"Unexpected error.");
}

- (nullable NSString *)recipientPicker:(RecipientPickerViewController *)recipientPickerViewController
          accessoryMessageForRecipient:(PickedRecipient *)recipient
{
    OWSAssertDebug(recipient.address.isValid);

    BOOL isPreviousMember = [self.previousMemberRecipients containsObject:recipient];
    BOOL isCurrentMember = [self.memberRecipients containsObject:recipient];
    BOOL isBlocked = [self.recipientPicker.contactsViewHelper isSignalServiceAddressBlocked:recipient.address];

    if (isCurrentMember && !isPreviousMember) {
        return NSLocalizedString(
            @"EDIT_GROUP_NEW_MEMBER_LABEL", @"An indicator that a user is a new member of the group.");
    } else if (isBlocked) {
        return MessageStrings.conversationIsBlocked;
    } else if (isCurrentMember) {
        return NSLocalizedString(@"NEW_GROUP_MEMBER_LABEL", @"An indicator that a user is a member of the new group.");
    } else {
        return nil;
    }
}

- (void)recipientPickerTableViewWillBeginDragging:(RecipientPickerViewController *)recipientPickerViewController
{
    [self.groupNameTextField resignFirstResponder];
}

- (void)recipientPickerNewGroupButtonWasPressed
{
    OWSFailDebug(@"Invalid action.");
}

- (NSArray<UIView *> *)recipientPickerCustomHeaderViews
{
    return @[];
}

#pragma mark - OWSNavigationView

- (BOOL)shouldCancelNavigationBack
{
    BOOL result = self.hasUnsavedChanges;
    if (result) {
        [self backButtonPressed];
    }
    return result;
}

@end

NS_ASSUME_NONNULL_END
