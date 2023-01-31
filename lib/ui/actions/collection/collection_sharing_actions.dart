import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/models/api/collection/create_request.dart';
import 'package:photos/models/collection.dart';
import 'package:photos/models/file.dart';
import 'package:photos/models/files_split.dart';
import 'package:photos/models/magic_metadata.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/hidden_service.dart';
import 'package:photos/services/user_service.dart';
import 'package:photos/theme/colors.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/ui/common/progress_dialog.dart';
import 'package:photos/ui/components/action_sheet_widget.dart';
import 'package:photos/ui/components/button_widget.dart';
import 'package:photos/ui/components/models/button_type.dart';
import 'package:photos/ui/payment/subscription.dart';
import 'package:photos/utils/date_time_util.dart';
import 'package:photos/utils/dialog_util.dart';
import 'package:photos/utils/email_util.dart';
import 'package:photos/utils/share_util.dart';
import 'package:photos/utils/toast_util.dart';

class CollectionActions {
  final Logger logger = Logger((CollectionActions).toString());
  final CollectionsService collectionsService;

  CollectionActions(this.collectionsService);

  Future<bool> enableUrl(
    BuildContext context,
    Collection collection, {
    bool enableCollect = false,
  }) async {
    final dialog = createProgressDialog(
      context,
      "Creating link...",
      isDismissible: true,
    );
    try {
      await dialog.show();
      await CollectionsService.instance.createShareUrl(
        collection,
        enableCollect: enableCollect,
      );
      dialog.hide();
      return true;
    } catch (e) {
      dialog.hide();
      if (e is SharingNotPermittedForFreeAccountsError) {
        _showUnSupportedAlert(context);
      } else {
        logger.severe("Failed to update shareUrl collection", e);
        showGenericErrorDialog(context: context);
      }
      return false;
    }
  }

  Future<bool> disableUrl(BuildContext context, Collection collection) async {
    final ButtonAction? result = await showActionSheet(
      context: context,
      buttons: [
        ButtonWidget(
          buttonType: ButtonType.critical,
          isInAlert: true,
          shouldStickToDarkTheme: true,
          buttonAction: ButtonAction.first,
          shouldSurfaceExecutionStates: true,
          labelText: "Yes, remove",
          onTap: () async {
            await CollectionsService.instance.disableShareUrl(collection);
          },
        ),
        const ButtonWidget(
          buttonType: ButtonType.secondary,
          buttonAction: ButtonAction.cancel,
          isInAlert: true,
          shouldStickToDarkTheme: true,
          labelText: "Cancel",
        )
      ],
      title: "Remove public link",
      body:
          'This will remove the public link for accessing "${collection.name}".',
    );
    if (result != null) {
      if (result == ButtonAction.error) {
        showGenericErrorDialog(context: context);
      }
      return result == ButtonAction.first;
    } else {
      return false;
    }
  }

  Future<Collection?> createSharedCollectionLink(
    BuildContext context,
    List<File> files,
  ) async {
    final dialog =
        createProgressDialog(context, "Creating link...", isDismissible: true);
    dialog.show();
    try {
      // create album with emptyName, use collectionCreationTime on UI to
      // show name
      logger.finest("creating album for sharing files");
      final File fileWithMinCreationTime = files.reduce(
        (a, b) => (a.creationTime ?? 0) < (b.creationTime ?? 0) ? a : b,
      );
      final File fileWithMaxCreationTime = files.reduce(
        (a, b) => (a.creationTime ?? 0) > (b.creationTime ?? 0) ? a : b,
      );
      final String dummyName = getNameForDateRange(
        fileWithMinCreationTime.creationTime!,
        fileWithMaxCreationTime.creationTime!,
      );
      final CreateRequest req =
          await collectionsService.buildCollectionCreateRequest(
        dummyName,
        visibility: visibilityVisible,
        subType: subTypeSharedFilesCollection,
      );
      final collection = await collectionsService.createAndCacheCollection(
        req,
      );
      logger.finest("adding files to share to new album");
      await collectionsService.addToCollection(collection.id, files);
      logger.finest("creating public link for the newly created album");
      await CollectionsService.instance.createShareUrl(collection);
      dialog.hide();
      return collection;
    } catch (e, s) {
      dialog.hide();
      showGenericErrorDialog(context: context);
      logger.severe("Failing to create link for selected files", e, s);
    }
    return null;
  }

  // removeParticipant remove the user from a share album
  Future<bool?> removeParticipant(
    BuildContext context,
    Collection collection,
    User user,
  ) async {
    final result = await showChoiceDialog(
      context,
      title: "Remove",
      body: "${user.email} will be removed",
      firstButtonLabel: "Yes, remove",
      firstButtonOnTap: () async {
        try {
          final newSharees = await CollectionsService.instance
              .unshare(collection.id, user.email);
          collection.updateSharees(newSharees);
        } catch (e, s) {
          Logger("EmailItemWidget").severe(e, s);
          rethrow;
        }
      },
    );
    if (result == ButtonAction.error) {
      await showGenericErrorDialog(context: context);
      return false;
    }
    if (result == ButtonAction.first) {
      return true;
    } else {
      return false;
    }
  }

  Future<bool?> addEmailToCollection(
    BuildContext context,
    Collection collection,
    String email, {
    CollectionParticipantRole role = CollectionParticipantRole.viewer,
    bool showProgress = false,
    String? publicKey,
  }) async {
    if (!isValidEmail(email)) {
      await showErrorDialog(
        context,
        "Invalid email address",
        "Please enter a valid email address.",
      );
      return null;
    } else if (email == Configuration.instance.getEmail()) {
      await showErrorDialog(context, "Oops", "You cannot share with yourself");
      return null;
    }

    ProgressDialog? dialog;
    if (publicKey == null) {
      if (showProgress) {
        dialog = createProgressDialog(context, "Searching for user...");
        await dialog.show();
      }

      try {
        publicKey = await UserService.instance.getPublicKey(email);
        await dialog?.hide();
      } catch (e) {
        await dialog?.hide();
        logger.severe("Failed to get public key", e);
        showGenericErrorDialog(context: context);
        return false;
      }
    }
    // getPublicKey can return null
    // ignore: unnecessary_null_comparison
    if (publicKey == null || publicKey == '') {
      final alertDialog = AlertDialog(
        title: const Text("Invite to ente?"),
        content: Text(
          "Looks like " +
              email +
              " hasn't signed up for ente yet. would you like to invite them?",
          style: const TextStyle(
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            child: Text(
              "Invite",
              style: TextStyle(
                color: Theme.of(context).colorScheme.greenAlternative,
              ),
            ),
            onPressed: () {
              shareText(
                "Hey, I have some photos to share. Please install https://ente.io so that I can share them privately.",
              );
            },
          ),
        ],
      );
      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return alertDialog;
        },
      );
      return null;
    } else {
      if (showProgress) {
        dialog = createProgressDialog(
          context,
          "Sharing...",
          isDismissible: true,
        );
        await dialog.show();
      }
      try {
        final newSharees = await CollectionsService.instance
            .share(collection.id, email, publicKey, role);
        await dialog?.hide();
        collection.updateSharees(newSharees);
        return true;
      } catch (e) {
        await dialog?.hide();
        if (e is SharingNotPermittedForFreeAccountsError) {
          _showUnSupportedAlert(context);
        } else {
          logger.severe("failed to share collection", e);
          showGenericErrorDialog(context: context);
        }
        return false;
      }
    }
  }

  Future<bool> deleteCollectionSheet(
    BuildContext bContext,
    Collection collection,
  ) async {
    final textTheme = getEnteTextTheme(bContext);
    final currentUserID = Configuration.instance.getUserID()!;
    if (collection.owner!.id != currentUserID) {
      throw AssertionError("Can not delete album owned by others");
    }
    final actionResult = await showActionSheet(
      context: bContext,
      buttons: [
        ButtonWidget(
          labelText: "Keep Photos",
          buttonType: ButtonType.neutral,
          buttonSize: ButtonSize.large,
          buttonAction: ButtonAction.first,
          shouldStickToDarkTheme: true,
          isInAlert: true,
          onTap: () async {
            try {
              final List<File> files =
                  await FilesDB.instance.getAllFilesCollection(collection.id);
              await moveFilesFromCurrentCollection(bContext, collection, files);
              // collection should be empty on server now
              await collectionsService.trashEmptyCollection(collection);
            } catch (e) {
              logger.severe("Failed to keep photos and delete collection", e);
              rethrow;
            }
          },
        ),
        ButtonWidget(
          labelText: "Delete photos",
          buttonType: ButtonType.critical,
          buttonSize: ButtonSize.large,
          buttonAction: ButtonAction.second,
          shouldStickToDarkTheme: true,
          isInAlert: true,
          onTap: () async {
            try {
              await collectionsService.trashNonEmptyCollection(collection);
            } catch (e) {
              logger.severe("Failed to delete collection", e);
              rethrow;
            }
          },
        ),
        const ButtonWidget(
          labelText: "Cancel",
          buttonType: ButtonType.secondary,
          buttonSize: ButtonSize.large,
          buttonAction: ButtonAction.third,
          shouldStickToDarkTheme: true,
          isInAlert: true,
        ),
      ],
      bodyWidget: RichText(
        text: TextSpan(
          style: textTheme.body.copyWith(color: textMutedDark),
          children: <TextSpan>[
            const TextSpan(
              text: 'Also delete the photos (and videos) present in this '
                  'album from ',
            ),
            TextSpan(
              text: 'all',
              style: textTheme.body.copyWith(color: textBaseDark),
            ),
            const TextSpan(
              text: ' other albums they are part of?',
            ),
          ],
        ),
      ),
      actionSheetType: ActionSheetType.defaultActionSheet,
    );
    if (actionResult != null && actionResult == ButtonAction.error) {
      showGenericErrorDialog(context: bContext);
      return false;
    }
    if (actionResult != null &&
        (actionResult == ButtonAction.first ||
            actionResult == ButtonAction.second)) {
      return true;
    }
    return false;
  }

  /*
  _moveFilesFromCurrentCollection removes the file from the current
  collection. Based on the file and collection ownership, files will be
  either moved to different collection (Case A). or will just get removed
  from current collection (Case B).
  -------------------------------
  Case A: Files and collection belong to the same user. Such files
  will be moved to a collection which belongs to the user and removed from
  the current collection as part of move operation.
  Note: Even files are present in the
  destination collection, we need to make move API call on the server
  so that the files are removed from current collection and are actually
  moved to a collection owned by the user.
  -------------------------------
  Case B: Owner of files and collections are different. In such cases,
  we will just remove (not move) the files from the given collection.
  */
  Future<void> moveFilesFromCurrentCollection(
    BuildContext context,
    Collection collection,
    Iterable<File> files,
  ) async {
    final int currentUserID = Configuration.instance.getUserID()!;
    final isCollectionOwner = collection.owner!.id == currentUserID;
    final FilesSplit split = FilesSplit.split(
      files,
      Configuration.instance.getUserID()!,
    );
    if (isCollectionOwner && split.ownedByOtherUsers.isNotEmpty) {
      await collectionsService.removeFromCollection(
        collection.id,
        split.ownedByOtherUsers,
      );
    } else if (!isCollectionOwner && split.ownedByCurrentUser.isNotEmpty) {
      // collection is not owned by the user, just remove files owned
      // by current user and return
      await collectionsService.removeFromCollection(
        collection.id,
        split.ownedByCurrentUser,
      );
      return;
    }

    if (!isCollectionOwner && split.ownedByOtherUsers.isNotEmpty) {
      showShortToast(context, "Can only remove files owned by you");
      return;
    }

    // pendingAssignMap keeps a track of files which are yet to be assigned to
    // to destination collection.
    final Map<int, File> pendingAssignMap = {};
    // destCollectionToFilesMap contains the destination collection and
    // files entry which needs to be moved in destination.
    // After the end of mapping logic, the number of files entries in
    // pendingAssignMap should be equal to files in destCollectionToFilesMap
    final Map<int, List<File>> destCollectionToFilesMap = {};
    final List<int> uploadedIDs = [];
    for (File f in split.ownedByCurrentUser) {
      if (f.uploadedFileID != null) {
        pendingAssignMap[f.uploadedFileID!] = f;
        uploadedIDs.add(f.uploadedFileID!);
      }
    }

    final Map<int, List<File>> collectionToFilesMap =
        await FilesDB.instance.getAllFilesGroupByCollectionID(uploadedIDs);

    // Find and map the files from current collection to to entries in other
    // collections. This mapping is done to avoid moving all the files to
    // uncategorized during remove from album.
    for (MapEntry<int, List<File>> entry in collectionToFilesMap.entries) {
      if (!_isAutoMoveCandidate(collection.id, entry.key, currentUserID)) {
        continue;
      }
      final targetCollection = collectionsService.getCollectionByID(entry.key)!;
      // for each file which already exist in the destination collection
      // add entries in the moveDestCollectionToFiles map
      for (File file in entry.value) {
        // Check if the uploaded file is still waiting to be mapped
        if (pendingAssignMap.containsKey(file.uploadedFileID)) {
          if (!destCollectionToFilesMap.containsKey(targetCollection.id)) {
            destCollectionToFilesMap[targetCollection.id] = <File>[];
          }
          destCollectionToFilesMap[targetCollection.id]!
              .add(pendingAssignMap[file.uploadedFileID!]!);
          pendingAssignMap.remove(file.uploadedFileID);
        }
      }
    }
    // Move the remaining files to uncategorized collection
    if (pendingAssignMap.isNotEmpty) {
      final Collection uncategorizedCollection =
          await collectionsService.getUncategorizedCollection();
      final int toCollectionID = uncategorizedCollection.id;
      for (MapEntry<int, File> entry in pendingAssignMap.entries) {
        final file = entry.value;
        if (pendingAssignMap.containsKey(file.uploadedFileID)) {
          if (!destCollectionToFilesMap.containsKey(toCollectionID)) {
            destCollectionToFilesMap[toCollectionID] = <File>[];
          }
          destCollectionToFilesMap[toCollectionID]!
              .add(pendingAssignMap[file.uploadedFileID!]!);
        }
      }
    }

    // Verify that all files are mapped.
    int mappedFilesCount = 0;
    destCollectionToFilesMap.forEach((key, value) {
      mappedFilesCount += value.length;
    });
    if (mappedFilesCount != uploadedIDs.length) {
      throw AssertionError(
        "Failed to map all files toMap: ${uploadedIDs.length} and mapped "
        "$mappedFilesCount",
      );
    }

    for (MapEntry<int, List<File>> entry in destCollectionToFilesMap.entries) {
      await collectionsService.move(entry.key, collection.id, entry.value);
    }
  }

  // This method returns true if the given destination collection is a good
  // target to moving files during file remove or delete collection but keey
  // photos action. Uncategorized or favorite type of collections are not
  // good auto-move candidates. Uncategorized will be fall back for all files
  // which could not be mapped to a potential target collection
  bool _isAutoMoveCandidate(int fromCollectionID, toCollectionID, int userID) {
    if (fromCollectionID == toCollectionID) {
      return false;
    }
    final Collection? targetCollection =
        collectionsService.getCollectionByID(toCollectionID);
    // ignore non-cached collections, uncategorized and favorite
    // collections and collections ignored by others
    if (targetCollection == null ||
        (CollectionType.uncategorized == targetCollection.type ||
            targetCollection.type == CollectionType.favorites) ||
        targetCollection.owner!.id != userID) {
      return false;
    }
    return true;
  }

  void _showUnSupportedAlert(BuildContext context) {
    final AlertDialog alert = AlertDialog(
      title: const Text("Sorry"),
      content: const Text(
        "Looks like your subscription has expired. Please subscribe to enable"
        " sharing.",
      ),
      actions: [
        TextButton(
          child: Text(
            "Subscribe",
            style: TextStyle(
              color: Theme.of(context).colorScheme.greenAlternative,
            ),
          ),
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (BuildContext context) {
                  return getSubscriptionPage();
                },
              ),
            );
          },
        ),
        TextButton(
          child: Text(
            "Ok",
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
      ],
    );

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return alert;
      },
    );
  }
}
