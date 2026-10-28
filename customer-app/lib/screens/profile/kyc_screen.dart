import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/kyc.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/primary_button.dart';

String _t(String en, String so) => AppLanguage.isSomali ? so : en;

/// Picks a photo: the document (camera or gallery) or a selfie (front camera).
typedef KycPhotoPicker = Future<Uint8List?> Function(BuildContext context, {required bool selfie});

Future<Uint8List?> pickKycPhoto(BuildContext context, {required bool selfie}) async {
  final source = selfie
      ? ImageSource.camera
      : await showModalBottomSheet<ImageSource>(
          context: context,
          builder: (context) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: Text(_t('Take a photo', 'Sawir qaado')),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: Text(_t('Choose from gallery', 'Ka dooro sawirada')),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ]),
          ),
        );
  if (source == null) return null;
  final file = await ImagePicker().pickImage(
    source: source,
    preferredCameraDevice: selfie ? CameraDevice.front : CameraDevice.rear,
    maxWidth: 1800,
    maxHeight: 1800,
    imageQuality: 85,
  );
  return file?.readAsBytes();
}

/// KYC Verification (customer_kyc_status / customer_submit_kyc): the status,
/// or the steps -- document type, details and photo(s), selfie, review --
/// then the status with its timeline. The server checks everything and an
/// admin (or an identity service, when one is set up) decides.
class KycScreen extends StatefulWidget {
  const KycScreen({super.key, this.pickPhoto = pickKycPhoto});

  final KycPhotoPicker pickPhoto;

  @override
  State<KycScreen> createState() => _KycScreenState();
}

enum _Step { status, intro, type, details, selfie, review }

class _KycScreenState extends State<KycScreen> {
  static final _iso = DateFormat('yyyy-MM-dd');
  static final _when = DateFormat('d MMM yyyy, HH:mm');

  KycStatus? _status;
  String? _error;
  bool _loading = true;
  bool _submitting = false;
  _Step _step = _Step.status;

  String _type = 'passport';
  final _name = TextEditingController();
  final _number = TextEditingController();
  String _country = 'SO';
  DateTime? _dob;
  DateTime? _expiry;
  Uint8List? _front;
  Uint8List? _back;
  Uint8List? _selfie;
  final _form = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await context.read<CustomerApi>().getKycStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _loading = false;
        _step = s.status == 'not_submitted' ? _Step.intro : _Step.status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : AppStrings.somethingWentWrong;
        _loading = false;
      });
    }
  }

  Future<void> _pick(String which) async {
    final bytes = await widget.pickPhoto(context, selfie: which == 'selfie');
    if (bytes == null || !mounted) return;
    setState(() {
      if (which == 'front') _front = bytes;
      if (which == 'back') _back = bytes;
      if (which == 'selfie') _selfie = bytes;
    });
  }

  Future<void> _pickDate({required bool birth}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: birth ? DateTime(now.year - 25) : DateTime(now.year + 2),
      firstDate: birth ? DateTime(1920) : now,
      lastDate: birth ? now : DateTime(now.year + 20),
    );
    if (picked == null) return;
    setState(() => birth ? _dob = picked : _expiry = picked);
  }

  bool get _detailsReady =>
      _name.text.trim().isNotEmpty && _number.text.trim().isNotEmpty && _dob != null && _expiry != null &&
      _front != null && (_type == 'passport' || _back != null);

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final s = await context.read<CustomerApi>().submitKyc(
            documentType: _type,
            fullName: _name.text.trim(),
            documentNumber: _number.text.trim(),
            country: _country,
            dateOfBirth: _iso.format(_dob!),
            expiryDate: _iso.format(_expiry!),
            front: _front!,
            back: _type == 'national_id' ? _back : null,
            selfie: _selfie!,
          );
      if (!mounted) return;
      setState(() {
        _status = s;
        _step = _Step.status;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = AppStrings.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _goBack() {
    final order = [_Step.intro, _Step.type, _Step.details, _Step.selfie, _Step.review];
    final i = order.indexOf(_step);
    if (i <= 0) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _step = order[i - 1]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      _Step.status => _t('KYC Status', 'Xaaladda KYC'),
      _Step.intro => _t('KYC Verification', 'Xaqiijinta KYC'),
      _Step.type => _t('Select Document Type', 'Dooro Nooca Dukumentiga'),
      _Step.details => _type == 'passport' ? _t('Passport Information', 'Xogta Baasaboorka') : _t('National ID', 'Kaarka Aqoonsiga'),
      _Step.selfie => _t('Take a Selfie', 'Sawir Is-qaad ah'),
      _Step.review => _t('Review & Submit', 'Hubi oo Dir'),
    };
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(
        title: Text(title),
        leading: _step == _Step.status
            ? null
            : IconButton(key: const Key('kyc-back'), icon: const Icon(Icons.arrow_back_rounded), onPressed: _goBack),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_status == null
                ? Center(child: Text(_error ?? '', style: AppTextStyles.muted))
                : ListView(
                    key: Key('kyc-${_step.name}'),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    children: [
                      ...switch (_step) {
                        _Step.status => _statusView(_status!),
                        _Step.intro => _intro(),
                        _Step.type => _typeView(),
                        _Step.details => _details(),
                        _Step.selfie => _selfieView(),
                        _Step.review => _review(),
                      },
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, key: const Key('kyc-error'), style: AppTextStyles.muted.copyWith(color: AppColors.error)),
                      ],
                    ],
                  )),
      ),
    );
  }

  List<Widget> _intro() => [
        Text(_t('Verify your identity to use all features including withdrawals.',
            'Xaqiiji aqoonsigaaga si aad u isticmaasho adeegyada oo dhan, oo ay ku jirto bixinta lacagta.'),
            textAlign: TextAlign.center, style: AppTextStyles.muted),
        const SizedBox(height: 24),
        Icon(Icons.verified_user_rounded, size: 110, color: AppColors.primary),
        const SizedBox(height: 24),
        _Point(icon: Icons.lock_rounded, title: _t('Secure & Safe', 'Ammaan'),
            text: _t('Your information is encrypted and kept private.', 'Xogtaada si ammaan ah ayaa loo hayaa.')),
        _Point(icon: Icons.bolt_rounded, title: _t('Faster Withdrawals', 'Bixin Degdeg ah'),
            text: _t('Get approved to withdraw without delays.', 'La fasax si aad lacag ula baxdo dib u dhac la\'aan.')),
        const SizedBox(height: 24),
        PrimaryButton(key: const Key('kyc-start'), label: _t('Start Verification', 'Bilow Xaqiijinta'),
            onPressed: () => setState(() => _step = _Step.type)),
      ];

  List<Widget> _typeView() => [
        Text(_t('Choose the type of identification document you want to use.', 'Dooro dukumentiga aqoonsiga aad isticmaalayso.'),
            style: AppTextStyles.muted),
        const SizedBox(height: 16),
        for (final (id, label, hint, icon) in [
          ('passport', _t('Passport', 'Baasaboor'), _t('Use your passport information page', 'Bogga xogta baasaboorka'), Icons.menu_book_rounded),
          ('national_id', _t('National ID', 'Kaarka Aqoonsiga'), _t('Use your national identity card (front and back)',
              'Kaarka aqoonsiga (hore iyo gadaal)'), Icons.badge_rounded),
        ])
          Card(
            key: Key('kyc-type-$id'),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: _type == id ? AppColors.primary : AppColors.cardBorder, width: _type == id ? 2 : 1)),
            child: RadioListTile<String>(
              value: id,
              groupValue: _type,
              onChanged: (v) => setState(() => _type = v!),
              secondary: Icon(icon, size: 36, color: AppColors.primary),
              title: Text(label, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
              subtitle: Text(hint, style: AppTextStyles.muted),
            ),
          ),
        const SizedBox(height: 20),
        PrimaryButton(key: const Key('kyc-type-continue'), label: AppStrings.continueLabel,
            onPressed: () => setState(() => _step = _Step.details)),
      ];

  Widget _photoBox(String which, String label, Uint8List? bytes) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppTextStyles.label),
          const SizedBox(height: 6),
          InkWell(
            key: Key('kyc-photo-$which'),
            onTap: () => _pick(which),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 140,
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: bytes == null ? AppColors.cardBorder : AppColors.statusCompleted),
              ),
              child: bytes == null
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.add_a_photo_rounded, color: AppColors.primary, size: 32),
                      const SizedBox(height: 6),
                      Text(_t('Add photo', 'Ku dar sawir'), style: AppTextStyles.muted),
                    ])
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: Image.memory(bytes, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_rounded)),
                    ),
            ),
          ),
        ]),
      );

  Widget _dateField(String label, DateTime? value, {required bool birth}) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: InkWell(
          key: Key(birth ? 'kyc-dob' : 'kyc-expiry'),
          onTap: () => _pickDate(birth: birth),
          child: InputDecorator(
            decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_month_rounded)),
            child: Text(value == null ? '' : _iso.format(value)),
          ),
        ),
      );

  List<Widget> _details() => [
        Text(_t('Enter your details exactly as shown on your document.', 'Geli xogtaada sida ay ugu qoran tahay dukumentiga.'),
            style: AppTextStyles.muted),
        Form(
          key: _form,
          onChanged: () => setState(() {}),
          child: Column(children: [
            TextFormField(
              key: const Key('kyc-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: _t('Full Name', 'Magaca oo dhan')),
            ),
            TextFormField(
              key: const Key('kyc-number'),
              controller: _number,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: _type == 'passport' ? _t('Passport Number', 'Lambarka Baasaboorka')
                  : _t('ID Number', 'Lambarka Aqoonsiga')),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              key: const Key('kyc-country'),
              value: _country,
              isExpanded: true,
              decoration: InputDecoration(labelText: _t('Country of Issue', 'Dalka laga bixiyay')),
              items: [for (final (code, name) in kycCountries) DropdownMenuItem(value: code, child: Text(name))],
              onChanged: (v) => setState(() => _country = v ?? _country),
            ),
            _dateField(_t('Date of Birth', 'Taariikhda Dhalashada'), _dob, birth: true),
            _dateField(_t('Expiry Date', 'Taariikhda Dhicitaanka'), _expiry, birth: false),
          ]),
        ),
        _photoBox('front', _type == 'passport' ? _t('Upload Passport Photo', 'Sawirka Baasaboorka') : _t('ID card: front', 'Kaarka: hore'), _front),
        if (_type == 'national_id') _photoBox('back', _t('ID card: back', 'Kaarka: gadaal'), _back),
        const SizedBox(height: 20),
        PrimaryButton(key: const Key('kyc-details-continue'), label: AppStrings.continueLabel,
            onPressed: _detailsReady ? () => setState(() => _step = _Step.selfie) : null),
      ];

  List<Widget> _selfieView() => [
        Text(_t('Take a clear selfie of your face. Make sure your face is well lit and visible.',
            'Is-sawir si cad. Wejigaagu ha iftiimo oo ha muuqdo.'), textAlign: TextAlign.center, style: AppTextStyles.muted),
        _photoBox('selfie', _t('Selfie', 'Sawir is-qaad ah'), _selfie),
        const SizedBox(height: 10),
        for (final tip in [_t('Good lighting', 'Iftiin wanaagsan'), _t('Face clearly visible', 'Wejiga si cad u muuqda'),
          _t('No sunglasses or mask', 'Muraayad madow iyo maaskaro la\'aan')])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, color: AppColors.statusCompleted, size: 20),
              const SizedBox(width: 8),
              Text(tip, style: AppTextStyles.body),
            ]),
          ),
        const SizedBox(height: 20),
        PrimaryButton(key: const Key('kyc-selfie-continue'), label: AppStrings.continueLabel,
            onPressed: _selfie == null ? null : () => setState(() => _step = _Step.review)),
      ];

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppTextStyles.muted),
          Text(value, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );

  List<Widget> _review() => [
        Text(_t('Please review your information before submitting.', 'Fadlan hubi xogtaada intaadan dirin.'), style: AppTextStyles.muted),
        const SizedBox(height: 10),
        _row(_t('Document Type', 'Nooca Dukumentiga'), _type == 'passport' ? _t('Passport', 'Baasaboor') : _t('National ID', 'Kaarka Aqoonsiga')),
        _row(_t('Full Name', 'Magaca'), _name.text.trim()),
        _row(_type == 'passport' ? _t('Passport Number', 'Lambarka Baasaboorka') : _t('ID Number', 'Lambarka Aqoonsiga'), _number.text.trim().toUpperCase()),
        _row(_t('Country of Issue', 'Dalka'), kycCountries.firstWhere((c) => c.$1 == _country, orElse: () => (_country, _country)).$2),
        _row(_t('Date of Birth', 'Taariikhda Dhalashada'), _dob == null ? '' : _iso.format(_dob!)),
        _row(_t('Expiry Date', 'Taariikhda Dhicitaanka'), _expiry == null ? '' : _iso.format(_expiry!)),
        const SizedBox(height: 8),
        Row(children: [
          for (final b in [_front, if (_type == 'national_id') _back, _selfie])
            if (b != null)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(height: 90, child: Image.memory(b, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_rounded))),
                  ),
                ),
              ),
        ]),
        const SizedBox(height: 20),
        PrimaryButton(key: const Key('kyc-submit'), label: _t('Submit for Verification', 'U dir Xaqiijin'),
            onPressed: _submitting ? null : _submit, loading: _submitting),
      ];

  List<Widget> _statusView(KycStatus s) {
    final (icon, color, title, text) = switch (s.status) {
      'approved' => (Icons.check_circle_rounded, AppColors.statusCompleted, _t('KYC Approved', 'KYC waa la ansixiyay'),
          _t('Your identity has been verified. You can now make withdrawals and use all features.',
              'Aqoonsigaaga waa la xaqiijiyay. Hadda waad lacag ula bixi kartaa.')),
      'pending_auto' => (Icons.hourglass_top_rounded, AppColors.statusPending, _t('Pending Automatic Verification', 'Xaqiijin toos ah ayaa socota'),
          _t('Your documents are being checked.', 'Dukumentiyadaada waa la hubinayaa.')),
      'pending_review' => (Icons.manage_search_rounded, AppColors.statusPending, _t('Pending Admin Review', 'Maamulka ayaa eegaya'),
          _t('An admin is checking your documents. You will be told the result here.', 'Maamulka ayaa hubinaya dukumentiyadaada. Natiijada halkan ayaad ka arki doontaa.')),
      'rejected' => (Icons.cancel_rounded, AppColors.error, _t('KYC Rejected', 'KYC waa la diiday'), s.reason ?? ''),
      'resubmission_required' => (Icons.restart_alt_rounded, AppColors.statusPending, _t('Resubmission Required', 'Mar kale dir'), s.reason ?? ''),
      _ => (Icons.info_rounded, AppColors.textMuted, _t('Not Submitted', 'Lama dirin'), ''),
    };
    String at(DateTime? d) => d == null ? '' : _when.format(d.toLocal());
    return [
      Container(
        key: Key('kyc-status-${s.status}'),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(18)),
        child: Column(children: [
          Icon(icon, color: color, size: 52),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: AppTextStyles.title.copyWith(fontSize: 21)),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(text, key: const Key('kyc-status-text'), textAlign: TextAlign.center, style: AppTextStyles.body),
          ],
          if (s.decidedAt != null) ...[
            const SizedBox(height: 8),
            Text(at(s.decidedAt), style: AppTextStyles.muted),
          ],
        ]),
      ),
      const SizedBox(height: 18),
      if (s.submittedAt != null) _Point(icon: Icons.check_circle_rounded, title: _t('Submitted', 'La diray'), text: at(s.submittedAt)),
      if (s.autoCheckedAt != null) _Point(icon: Icons.check_circle_rounded, title: _t('Automatic checks', 'Hubin toos ah'), text: at(s.autoCheckedAt)),
      if (s.decidedAt != null) _Point(icon: Icons.check_circle_rounded, title: title, text: at(s.decidedAt)),
      if (s.canSubmit && s.status != 'not_submitted') ...[
        const SizedBox(height: 16),
        PrimaryButton(key: const Key('kyc-resubmit'), label: _t('Submit again', 'Mar kale dir'),
            onPressed: () => setState(() {
                  _front = _back = _selfie = null;
                  _step = _Step.type;
                })),
      ],
    ];
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: AppColors.primary, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
              if (text.isNotEmpty) Text(text, style: AppTextStyles.muted),
            ]),
          ),
        ]),
      );
}
